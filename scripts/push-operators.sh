#!/bin/bash
set -euo pipefail

readonly CONFIG_NAME="imageset-config.yml"
PUSH_COMPLETED=false

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
    LOG_DIR="${BASEDIR}/logs"

    if [[ ! -d "$WORKDIR" || ! -w "$WORKDIR" ]]; then
        echo "ERROR: The mirror output directory is missing or not writable:"
        echo "  ${WORKDIR}"
        echo "  Check that the correct drive is mounted and contains the mirrored data."
        exit 1
    fi
    WORKDIR="$(realpath -- "$WORKDIR")"
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p -- "$LOG_DIR"
    fi
    if [[ ! -w "$LOG_DIR" ]]; then
        echo "ERROR: The transfer log directory is not writable:"
        echo "  ${LOG_DIR}"
        exit 1
    fi

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
    CONFIG_SHA256="$actual_checksum"

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
    local TRANSFER_REASON TARBALL_SIZE TARBALL_SHA256 MAPPING_SHA256

    read -r -p "Enter the destination registry (example: registry.example.com:5000): " REGISTRY
    REGISTRY="${REGISTRY#docker://}"
    if [[ -z "$REGISTRY" || "$REGISTRY" == *"://"* || "$REGISTRY" =~ [[:space:]] ]]; then
        echo "ERROR: Enter a registry host, optionally followed by a namespace, without a URL scheme."
        exit 1
    fi

    read -r -p "Reason for this transfer: " TRANSFER_REASON
    if [[ ! "$TRANSFER_REASON" =~ [^[:space:]] ]]; then
        echo "ERROR: A reason for the transfer is required."
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

    TARBALL_SIZE="$(stat -c '%s' -- "$TARBALL")"
    TARBALL_SHA256="$(sha256sum -- "$TARBALL")"
    TARBALL_SHA256="${TARBALL_SHA256%% *}"
    MAPPING_SHA256="$(sha256sum -- "${DRY_RUN_DIR}/mapping.txt")"
    MAPPING_SHA256="${MAPPING_SHA256%% *}"
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

    record_transfer "$REGISTRY" "$TRANSFER_REASON" "$TARBALL_SIZE" "$TARBALL_SHA256" "$MAPPING_SHA256" "$CLUSTER_RESOURCES"
}

record_transfer() {
    local REGISTRY="$1" TRANSFER_REASON="$2" TARBALL_SIZE="$3"
    local TARBALL_SHA256="$4" MAPPING_SHA256="$5" CLUSTER_RESOURCES="$6"
    local TIMESTAMP LOG_FILE

    TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    LOG_FILE="${LOG_DIR}/transfer-${TIMESTAMP}.log"
    if [[ -e "$LOG_FILE" ]]; then
        LOG_FILE="${LOG_DIR}/transfer-${TIMESTAMP}-$$.log"
    fi

    if ! (
        umask 077
        {
            printf 'Timestamp UTC: %s\n' "$TIMESTAMP"
            printf 'Result: successful\n'
            printf 'Reason: %s\n' "$TRANSFER_REASON"
            printf 'Destination registry: docker://%s\n' "$REGISTRY"
            printf 'ImageSetConfiguration: %s\n' "$CONFIG_FILE"
            printf 'ImageSetConfiguration SHA-256: %s\n' "$CONFIG_SHA256"
            printf 'Mirror tar: %s\n' "$(basename -- "$TARBALL")"
            printf 'Mirror tar size bytes: %s\n' "$TARBALL_SIZE"
            printf 'Mirror tar SHA-256: %s\n' "$TARBALL_SHA256"
            printf 'Image mapping: %s/working-dir/dry-run/mapping.txt\n' "$WORKDIR"
            printf 'Image mapping SHA-256: %s\n' "$MAPPING_SHA256"
            printf 'Cluster resources directory: %s\n' "$CLUSTER_RESOURCES"
            if [[ -d "$CLUSTER_RESOURCES" ]]; then
                printf 'Cluster resource files:\n'
                find "$CLUSTER_RESOURCES" -type f -print | sort
            else
                printf 'Cluster resource files: none generated\n'
            fi
        } > "$LOG_FILE"
    ); then
        echo "ERROR: The image push succeeded, but the transfer log could not be written:"
        echo "  ${LOG_FILE}"
        exit 1
    fi

    echo "Transfer details recorded in:"
    echo "  ${LOG_FILE}"
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
