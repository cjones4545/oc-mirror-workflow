#!/bin/bash
set -euo pipefail

readonly CONFIG_NAME="imageset-config.yml"
PUSH_COMPLETED=false

run_with_privileges() {
    if (( EUID == 0 )); then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "ERROR: Root privileges are required to save artifacts under /opt; run as root or install sudo."
        return 1
    fi
}

check_oc_mirror() {
    if ! command -v oc-mirror >/dev/null 2>&1; then
        echo "ERROR: oc-mirror was not found in PATH."
        echo "Install or configure the oc-mirror CLI on this host, then try again."
        exit 1
    fi
    if ! command -v podman >/dev/null 2>&1; then
        echo "ERROR: podman is required to log in to the destination registry."
        exit 1
    fi
}

gather_info() {
    local DRIVE TARBALL_INPUT TARBALL_RESPONSE
    echo
    read -r -p "Enter the removable media mount path of the oc-mirror drive (example: /mnt/e, /mnt/apricorn): " DRIVE
    DRIVE="${DRIVE%:}"
    DRIVE="${DRIVE%/}"
    if [[ -z "$DRIVE" ]]; then
        echo "ERROR: A drive mount path is required."
        exit 1
    fi
    BASEDIR="${DRIVE}/oc-mirror"
    WORKDIR="${BASEDIR}/output"

    if [[ ! -d "$WORKDIR" || ! -w "$WORKDIR" ]]; then
        echo "ERROR: The mirror output directory is missing or not writable:"
        echo "  ${WORKDIR}"
        echo "  Check that the correct drive is mounted and contains the mirrored data."
        exit 1
    fi
    WORKDIR="$(realpath -- "$WORKDIR")"

    if [[ ! -d "${WORKDIR}/working-dir" ]]; then
        echo "ERROR: The original oc-mirror working directory is missing:"
        echo "  ${WORKDIR}/working-dir"
        echo "Transfer the complete output directory from the connected system."
        exit 1
    fi
    if [[ ! -w "${WORKDIR}/working-dir" ]]; then
        echo "ERROR: The original oc-mirror working directory is not writable:"
        echo "  ${WORKDIR}/working-dir"
        exit 1
    fi

    CONFIG_FILE="${WORKDIR}/${CONFIG_NAME}"
    CONFIG_CHECKSUM="${CONFIG_FILE}.sha256"
    if [[ ! -f "$CONFIG_FILE" || ! -f "$CONFIG_CHECKSUM" ]]; then
        echo "ERROR: The original image set configuration and checksum are required:"
        echo "  ${CONFIG_FILE}"
        echo "  ${CONFIG_CHECKSUM}"
        echo "Re-run pull-operators.sh and transfer the complete output directory."
        exit 1
    fi
    local expected_checksum actual_checksum
    expected_checksum="$(<"$CONFIG_CHECKSUM")"
    actual_checksum="$(sha256sum -- "$CONFIG_FILE")"
    actual_checksum="${actual_checksum%% *}"
    if [[ ! "$expected_checksum" =~ ^[[:xdigit:]]{64}$ || "$expected_checksum" != "$actual_checksum" ]]; then
        echo "ERROR: The saved image set configuration does not match its recorded checksum."
        echo "Do not continue with a modified or mismatched configuration."
        exit 1
    fi

    shopt -s nullglob
    local archives=("${WORKDIR}"/mirror_*.tar)
    shopt -u nullglob
    if (( ${#archives[@]} == 0 )); then
        echo "ERROR: No mirror_*.tar archive was found in:"
        echo "  ${WORKDIR}"
        exit 1
    fi
    if (( ${#archives[@]} > 1 )); then
        echo "ERROR: More than one mirror archive is present in ${WORKDIR}."
        echo "The --from option consumes archives from a directory, not an individual tarball."
        echo "Separate the intended archive and its matching working-dir/config into its own output directory."
        exit 1
    fi

    TARBALL_INPUT="${archives[0]}"
    read -r -e -p "Tarball to mirror [${TARBALL_INPUT}]: " TARBALL_RESPONSE
    if [[ -n "$TARBALL_RESPONSE" ]]; then
        TARBALL_INPUT="$TARBALL_RESPONSE"
    fi
    if [[ ! -s "$TARBALL_INPUT" ]]; then
        echo "ERROR: The selected tarball does not exist or is empty:"
        echo "  ${TARBALL_INPUT}"
        exit 1
    fi
    TARBALL="$(realpath -- "$TARBALL_INPUT")"
    if [[ "$(dirname -- "$TARBALL")" != "$WORKDIR" || "$TARBALL" != "${archives[0]}" ]]; then
        echo "ERROR: Select the single mirror tarball in the output directory:"
        echo "  ${archives[0]}"
        exit 1
    fi

    echo
    echo "Using:"
    echo " Drive Path    : ${DRIVE}"
    echo " Mirror Data   : ${WORKDIR}"
    echo " Tarball       : ${TARBALL}"
    echo " Working Dir   : ${WORKDIR}/working-dir"
    echo " Image Set     : ${CONFIG_FILE}"
}

push_operators() {
    local REGISTRY REGISTRY_HOST CONFIRM DRY_RUN_DIR CLUSTER_RESOURCES

    read -r -p "Enter the destination registry (example: registry.example.com:5000): " REGISTRY
    REGISTRY="${REGISTRY#docker://}"
    if [[ -z "$REGISTRY" || "$REGISTRY" == *"://"* || "$REGISTRY" =~ [[:space:]] ]]; then
        echo "ERROR: Enter a registry host, optionally followed by a namespace, without a URL scheme."
        exit 1
    fi

    REGISTRY_HOST="${REGISTRY%%/*}"
    echo
    echo "Log in to ${REGISTRY_HOST}; Podman will prompt for credentials without exposing the password in the command."
    podman login "$REGISTRY_HOST"

    echo
    echo "Previewing the disk-to-registry operation (no images will be pushed)..."
    oc-mirror \
      --v2 \
      -c "$CONFIG_FILE" \
      --dry-run \
      --from "file://${WORKDIR}" \
      "docker://${REGISTRY}" \
      || {
          echo "ERROR: oc-mirror dry run failed. No images were pushed."
          exit 1
      }

    DRY_RUN_DIR="${WORKDIR}/working-dir/dry-run"
    if [[ ! -f "${DRY_RUN_DIR}/mapping.txt" ]]; then
        echo "ERROR: Dry run did not produce the expected image mapping:"
        echo "  ${DRY_RUN_DIR}/mapping.txt"
        echo "No images were pushed."
        exit 1
    fi

    echo
    echo "Dry-run image mapping:"
    echo "  ${DRY_RUN_DIR}/mapping.txt"
    echo "Cluster-resource preview files:"
    CLUSTER_RESOURCES="${DRY_RUN_DIR}/cluster-resources"
    if [[ -d "$CLUSTER_RESOURCES" ]]; then
        find "$CLUSTER_RESOURCES" -type f -print | sort
    else
        echo "  No cluster-resource preview directory was generated."
        echo "  Review the oc-mirror dry-run output before proceeding."
    fi

    echo
    echo "The dry run does not push images or apply cluster resources."
    echo "It cannot guarantee registry capacity, push permissions, or cluster compatibility."
    read -r -p "Proceed with the actual image push to docker://${REGISTRY}? [y/N] " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Stopped after dry run. No images were pushed and no cluster resources were applied."
        return
    fi

    if [[ ! -d /opt ]] || ! run_with_privileges test -w /opt; then
        echo "ERROR: The artifact destination /opt is unavailable or not writable."
        echo "No images were pushed."
        exit 1
    fi

    echo
    echo "Pushing images to docker://${REGISTRY}..."
    oc-mirror \
      --v2 \
      -c "$CONFIG_FILE" \
      --from "file://${WORKDIR}" \
      "docker://${REGISTRY}"
    PUSH_COMPLETED=true

    echo
    echo "Push complete. Generated cluster resources (not applied):"
    CLUSTER_RESOURCES="${WORKDIR}/working-dir/cluster-resources"
    if [[ -d "$CLUSTER_RESOURCES" ]]; then
        find "$CLUSTER_RESOURCES" -type f -print | sort
        echo "Review these before applying; IDMS/ITMS changes can trigger node restarts."
    else
        echo "  No cluster-resources directory was generated."
    fi

    save_artifacts "$REGISTRY" "$CLUSTER_RESOURCES"
}

save_artifacts() {
    local REGISTRY="$1" CLUSTER_RESOURCES="$2"
    local TIMESTAMP ARTIFACT_ROOT ARTIFACT_DIR TARBALL_NAME
    local TARBALL_SHA256 TARBALL_SIZE AVAILABLE_BYTES SPACE_RESERVE_BYTES
    local TARBALL_INCLUDED=false DEST_TARBALL PARTIAL_TARBALL COPIED_SHA256

    TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    ARTIFACT_ROOT=/opt/oc-mirror-artifacts
    ARTIFACT_DIR="${ARTIFACT_ROOT}/${TIMESTAMP}"
    if [[ -e "$ARTIFACT_DIR" ]]; then
        ARTIFACT_DIR="${ARTIFACT_DIR}-$$"
    fi
    run_with_privileges install -d -m 0755 -- "$ARTIFACT_ROOT"
    run_with_privileges mkdir -m 0755 -- "$ARTIFACT_DIR"

    TARBALL_NAME="$(basename -- "$TARBALL")"
    TARBALL_SIZE="$(stat -c '%s' -- "$TARBALL")"
    TARBALL_SHA256="$(sha256sum -- "$TARBALL")"
    TARBALL_SHA256="${TARBALL_SHA256%% *}"

    run_with_privileges install -m 0644 -- "$CONFIG_FILE" "${ARTIFACT_DIR}/${CONFIG_NAME}"
    run_with_privileges install -m 0644 -- "$CONFIG_CHECKSUM" "${ARTIFACT_DIR}/${CONFIG_NAME}.sha256"
    run_with_privileges install -m 0644 -- \
      "${WORKDIR}/working-dir/dry-run/mapping.txt" \
      "${ARTIFACT_DIR}/image-mapping.txt"
    if [[ -d "$CLUSTER_RESOURCES" ]]; then
        run_with_privileges cp -a -- "$CLUSTER_RESOURCES" "${ARTIFACT_DIR}/cluster-resources"
    fi

    AVAILABLE_BYTES="$(df -Pk "$ARTIFACT_ROOT" | awk 'NR == 2 {print $4 * 1024}')"
    if [[ ! "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Could not determine free space under ${ARTIFACT_ROOT}."
        exit 1
    fi
    SPACE_RESERVE_BYTES=1073741824
    if (( AVAILABLE_BYTES >= TARBALL_SIZE + SPACE_RESERVE_BYTES )); then
        DEST_TARBALL="${ARTIFACT_DIR}/${TARBALL_NAME}"
        PARTIAL_TARBALL="${DEST_TARBALL}.partial"
        echo "Archiving mirror tar to ${DEST_TARBALL}..."
        run_with_privileges install -m 0644 -- "$TARBALL" "$PARTIAL_TARBALL"
        COPIED_SHA256="$(run_with_privileges sha256sum -- "$PARTIAL_TARBALL")"
        COPIED_SHA256="${COPIED_SHA256%% *}"
        if [[ "$COPIED_SHA256" != "$TARBALL_SHA256" ]]; then
            echo "ERROR: Archived tar checksum does not match the source tar."
            exit 1
        fi
        run_with_privileges mv -- "$PARTIAL_TARBALL" "$DEST_TARBALL"
        TARBALL_INCLUDED=true
    else
        echo "Not enough free space to safely archive the mirror tar under ${ARTIFACT_ROOT}."
        echo "The tar will be omitted; its name, size, and SHA-256 will still be recorded."
    fi

    printf '%s  %s\n' "$TARBALL_SHA256" "$TARBALL_NAME" |
      run_with_privileges tee "${ARTIFACT_DIR}/${TARBALL_NAME}.sha256" >/dev/null
    {
        printf 'Timestamp UTC: %s\n' "$TIMESTAMP"
        printf 'Destination registry: docker://%s\n' "$REGISTRY"
        printf 'ImageSetConfiguration: %s\n' "$CONFIG_NAME"
        printf 'ImageSetConfiguration SHA-256: %s\n' "$CONFIG_SHA256"
        printf 'Mirror tar: %s\n' "$TARBALL_NAME"
        printf 'Mirror tar size bytes: %s\n' "$TARBALL_SIZE"
        printf 'Mirror tar SHA-256: %s\n' "$TARBALL_SHA256"
        printf 'Mirror tar copied to artifact bundle: %s\n' "$TARBALL_INCLUDED"
        printf 'Cluster resources copied: %s\n' "$([[ -d "$CLUSTER_RESOURCES" ]] && echo yes || echo no)"
        printf 'Image mapping: image-mapping.txt\n'
    } | run_with_privileges tee "${ARTIFACT_DIR}/artifact-manifest.txt" >/dev/null

    echo "Timestamped mirror artifacts saved under:"
    echo "  ${ARTIFACT_DIR}"
}

main() {
    check_oc_mirror
    gather_info
    push_operators
}

main "$@"

if [[ "$PUSH_COMPLETED" == true ]]; then
    echo "Mirror to the disconnected registry is complete."
else
    echo "Dry run is complete; the registry was not changed."
fi
