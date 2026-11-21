#!/bin/bash 
set -eou pipefail

readonly IMAGE="${OC_MIRROR_IMAGE:-localhost/oc-mirror:test}"

pull_oc() {
    local REGISTRY
    local USERNAME
    local PASSWORD
    echo "#############################"
    echo "# Preparing the environment #"
    echo "#############################"
    echo 
    echo "Installing podman on the WSL Image..."
    sudo apt upgrade -y 
    sudo apt install -y podman 

    echo "Logging into Gitlab instance..."
    read -p "Enter the Gitlab container registry URL (registry.example.com:443): " REGISTRY
    read -p "Enter your Gitlab Username (N number): " USERNAME
    read -sp "Enter your Gitlab Password: " PASSWORD
    echo

    if ! printf '%s' "$PASSWORD" | podman login \
        "$REGISTRY" \
        --username "$USERNAME" \
        --password-stdin 
    then 
        echo "Error: Login failed for $REGISTRY"
        unset PASSWORD
        exit 1
    fi 

    unset PASSWORD 

    echo "Pulling $IMAGE"
    podman pull $IMAGE
    echo

    echo "Environment all setup"
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
    [[ ! -f "${AUTHFILE}" ]] && {
        echo "ERROR: Pull secret not found:"
        echo "  ${AUTHFILE}"
        echo "  make sure you are in the project roots directory"
        exit 1
    }
    podman run --rm -it \
      -v "${CACHEDIR}:/cache:Z" \
      -v "${WORKDIR}:/work:Z" \
      -v "${IMAGESETS}:/imagesets:Z" \
      -v "${AUTHFILE}:/pull-secret.txt:Z" \
      "$IMAGE" \
      --authfile /pull-secret.txt \
      --cache-dir /cache \
      -c imagesets/original-isc.yml \
      file://${WORKDIR}
}

pull_operators

echo "Mirror to disk is complete --- Please make sure that you move the mirror tar off of the drive and into the environment"