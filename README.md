# Disconnected oc-mirror workflow 
### Purpose 
- To simplify and document the oc-mirror process for transferring data when there is no unlcass infrastructure available.

## Setup with Jorge before testing this
- Dedicate a singular drive to being the oc-mirror drive
- Create a layout inside of the drive as such: 
    - /mnt/oc-mirror
    - /mnt/oc-mirror/output
    - /mnt/oc-mirror/cache
    - /mnt/oc-mirror/logs

### Setup and workflow
1. Ensure you have requested Removable Media Access for your device
2. Make sure to have the drive plugged into your device
3. Download your pull-secret from console.redhat.com 
    - Navigate to https://console.redhat.com/openshift/downloads and at the bottom of the page you'll see a download button for the pull secret
    [![pull-secret](images/pullsecretdownload.png)
4. Install WSL on your Windows Laptop through software center 
5. Open a command prompt and type ```wsl```
6. Clone down this repo to the WSL image ```git clone <repo>.git```
7. Change directories to the cloned project
8. Place your downloaded pull-secret in the cloned project directory (preserve the pull-secret.txt name) 
9. Run the script to pull the operators down ```bash scripts/pull-operators.sh``` and follow the prompts. Use ```--wsl``` to if you're running this on WSL or ```--rhel``` if you're running this on a RHEL virtualbox VM
10. The following items are important that will be transferred to the disconnected environment: the ```oc-mirror/output``` directory, including the mirror tar ```mirror_000001.tar```, saved image set configuration, and checksum.
11. On a host in the disconnected environment with access to the target registry and the ```oc-mirror``` and ```podman``` CLIs available in its ```PATH```, run ```bash scripts/push-operators.sh```. Enter the drive path, confirm the tarball, destination registry, and reason for the transfer when prompted. Podman prompts for registry credentials securely. The script verifies the saved configuration checksum, previews the image mapping and cluster resources with ```oc-mirror --dry-run```, and requires confirmation before pushing. It does not apply cluster resources. After a successful push, it records a timestamped transfer log under ```oc-mirror/logs``` with the reason, destination, configuration and tar hashes, mapping hash, and cluster-resource paths.