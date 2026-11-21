#!/bin/bash 
set -eou pipefail

readonly IMAGE="${OC_MIRROR_IMAGE:-quay.io/rhn-support-carjones/oc-mirror:latest}"

pull_oc() {
    local REGISTRY
    local USERNAME
    local PASSWORD
    echo "#############################"
    echo "# Preparing the environment #"
    echo "#############################"
    echo 
    echo "Installing podman on the WSL Image..."
    sudo apt update -y 
    sudo apt install -y podman 
    echo
    echo "Pulling $IMAGE"
    podman pull $IMAGE
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
    pull_oc
    gather_info
    pull_operators
}

main "$@"

echo "Mirror to disk is complete --- Please make sure that you move the mirror tar off of the drive and into the environment"