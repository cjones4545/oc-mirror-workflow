#!/bin/bash 
set -eou pipefail

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

    IMAGE="localhost/oc-mirror:test"

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
    echo " Drive Letter  : ${DRIVE}"
    echo " Base Dir      : ${BASEDIR}"
    echo " Working Dir   : ${WORKDIR}"
    echo " Cache Dir     : ${CACHEDIR}"
}

pull_operators() {
    # pull_oc
    # gather_info
    AUTHFILE=$(pwd)/pull-secret.txt
    IMAGESETS=$(pwd)/imagesets
    [[ ! -f "${AUTHFILE}" ]] && {
        echo "ERROR: Pull secret not found:"
        echo "  ${AUTHFILE}"
        echo "  make sure you are in the project roots directory"
        exit 1
    }
    podman run --rm -it \
      -v "${CACHEDIR}:/cache" \
      -v "${WORKDIR}:/work" \
      -v "${IMAGESETS}:/imagesets:ro" \
      -v "${AUTHFILE}:/pull-secret.txt:ro" \
      "$IMAGE" \
      --authfile /pull-secret.txt \
      --cachedir /cache \
      -c original-isc.yml \
      file://${WORKDIR}
}

pull_operators
