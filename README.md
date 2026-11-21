# Disconnected oc-mirror workflow 
### Purpose 
- To simplify and document the oc-mirror process for transferring data when there is no unlcass infrastructure available.

## Setup with Jorge before testing this
- Dedicate a singular drive to being the oc-mirror drive
- Create a layout inside of the drive as such: 
    - /mnt/oc-mirror
    - /mnt/oc-mirror/output
    - /mnt/oc-mirror/cache

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
9. Run the script to pull the operators down ```bash scripts/pull-operators.sh``` and follow the prompts 
10. Transfer the following 4 items to the disconnected environment: ```oc-mirror/output``` directory to the airgapped environment, including the mirror tar ```mirror_000001.tar```, saved image set configuration, and checksum.
11. On a host in the disconnected environment with access to the target registry and the ```oc-mirror``` CLI available in its ```PATH```, run ```bash scripts/push-operators.sh```. Enter the drive path, confirm the tarball, and enter the destination registry when prompted. The script verifies the saved configuration checksum, runs an ```oc-mirror --dry-run``` preview, and requires confirmation before pushing images. It does not apply the generated cluster resources. The auth file defaults to ```pull-secret.txt``` in the project root; set ```OC_MIRROR_AUTHFILE``` to use a different file containing credentials for the destination registry.