#!/bin/bash 
set -eou pipefail

readonly IMAGE="${OC_MIRROR_IMAGE:-quay.io/rhn-support-carjones/oc-mirror:latest}"
INSTALL_PLATFORM=auto

install_podman() {
    echo "Installing podman on this host..."
    case "$INSTALL_PLATFORM" in
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y podman
            elif command -v yum >/dev/null 2>&1; then
                sudo yum install -y podman
            else
                echo "ERROR: --rhel was specified, but neither dnf nor yum is available."
                exit 1
            fi
            ;;
        wsl)
            if ! command -v apt-get >/dev/null 2>&1; then
                echo "ERROR: --wsl was specified, but apt-get is not available."
                exit 1
            fi
            sudo apt-get update
            sudo apt-get install -y podman
            ;;
        auto)
            if command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y podman
            elif command -v yum >/dev/null 2>&1; then
                sudo yum install -y podman
            elif command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update
                sudo apt-get install -y podman
            else
                echo "ERROR: Cannot install podman: no supported package manager (dnf, yum, or apt-get) was found."
                exit 1
            fi
            ;;
    esac

    if ! command -v podman >/dev/null 2>&1; then
        echo "ERROR: Package installation completed, but podman is still not available in PATH."
        exit 1
    fi
}

pull_oc() {
    echo "#############################"
    echo "# Preparing the environment #"
    echo "#############################"
    echo
    if command -v podman >/dev/null 2>&1; then
        echo "Podman is already installed."
    else
        install_podman
    fi
    echo
    echo "Pulling $IMAGE"
    podman pull "$IMAGE"
    echo
    echo "Image pulled and continuing..."
    echo
}

gather_info() {
    echo 
    read -p "Enter the removable media mount path of the oc-mirror drive (example: /mnt/e, /mnt/apricorn) " DRIVE
    DRIVE=$(echo "$DRIVE" | tr '[:upper:]' '[:lower:]')
    DRIVE=${DRIVE%:}
    BASEDIR="${DRIVE}/oc-mirror"
    CACHEDIR="${BASEDIR}/cache"
    WORKDIR="${BASEDIR}/output"
    if [[ ! -w "$BASEDIR" ]]; then 
      echo "ERROR: "
      echo "  $DRIVE is either not writable or does not exist"
      echo "  check to make sure this directory is valid"
      exit 1
    fi 
    echo 
    echo "Using:"
    echo " Drive Path  : ${DRIVE}"
    echo " Base Dir      : ${BASEDIR}"
    echo " Working Dir   : ${WORKDIR}"
    echo " Cache Dir     : ${CACHEDIR}"
}

pull_operators() {
    AUTHFILE=$(pwd)/pull-secret.txt
    IMAGESETS=$(pwd)/imagesets
    IMAGESET_CONFIG="${IMAGESETS}/original-isc.yml"
    [[ ! -f "${AUTHFILE}" ]] && {
        echo "ERROR: Pull secret not found:"
        echo "  ${AUTHFILE}"
        echo "  make sure you are in the project roots directory"
        exit 1
    }
    [[ ! -f "${IMAGESET_CONFIG}" ]] && {
        echo "ERROR: Image set configuration not found:"
        echo "  ${IMAGESET_CONFIG}"
        exit 1
    }
    podman run --rm -it \
      -v "${CACHEDIR}:/cache" \
      -v "${WORKDIR}:/work" \
      -v "${IMAGESETS}:/imagesets" \
      -v "${AUTHFILE}:/pull-secret.txt" \
      "$IMAGE" \
      --authfile /pull-secret.txt \
      --cache-dir /cache \
      -c /imagesets/original-isc.yml \
      file:///work

    cp -- "${IMAGESET_CONFIG}" "${WORKDIR}/imageset-config.yml"
    sha256sum -- "${WORKDIR}/imageset-config.yml" | cut -d ' ' -f 1 > "${WORKDIR}/imageset-config.yml.sha256"
}

main() {
    while (($#)); do
        case "$1" in
            --rhel)
                if [[ "$INSTALL_PLATFORM" == wsl ]]; then
                    echo "ERROR: --rhel and --wsl cannot be used together."
                    exit 2
                fi
                INSTALL_PLATFORM=rhel
                ;;
            --wsl)
                if [[ "$INSTALL_PLATFORM" == rhel ]]; then
                    echo "ERROR: --rhel and --wsl cannot be used together."
                    exit 2
                fi
                INSTALL_PLATFORM=wsl
                ;;
            -h|--help)
                echo "Usage: $0 [--rhel | --wsl]"
                echo "Podman is detected automatically; these options select the installer if it is missing."
                exit 0
                ;;
            *)
                echo "ERROR: Unknown option: $1"
                echo "Usage: $0 [--rhel | --wsl]"
                exit 2
                ;;
        esac
        shift
    done

    pull_oc
    gather_info
    pull_operators
}

main "$@"

echo "Mirror to disk is complete --- Please make sure that you move the mirror tar off of the drive and into the environment"