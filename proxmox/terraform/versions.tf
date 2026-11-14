terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.122"
    }
  }
}

# Runs on the Proxmox host itself, against its own API.
# Credentials come from the environment, never from files in this repo:
#   export PROXMOX_VE_USERNAME=root@pam
#   read -rsp 'root password: ' PROXMOX_VE_PASSWORD; export PROXMOX_VE_PASSWORD
# root@pam (not an API token) is required: Proxmox only lets root@pam set a hookscript
# and raw QEMU args, and both are used below.
provider "proxmox" {
  endpoint = "https://127.0.0.1:8006/"
  insecure = true # self-signed cert on localhost
}
