variable "node_name" {
  description = "Proxmox node name (hostname of the host)."
  type        = string
  default     = "kabangy"
}

variable "ssh_public_keys" {
  description = "Public keys allowed to log in as the guest user."
  type        = list(string)
}

variable "guest_user" {
  type    = string
  default = "james"
}

variable "radeon_vm" {
  description = "llm-radeon VM settings."
  type = object({
    vm_id     = number
    ip_cidr   = string
    cores     = number
    memory_mb = number
    disk_gb   = number
    # PCI address of the Radeon VII without the function (passes .0 GPU and .1 audio).
    # Check with: lspci -D -d 1002:66af
    pci_id = string
  })
  default = {
    vm_id     = 111
    ip_cidr   = "10.10.10.11/24"
    cores     = 8
    memory_mb = 6144
    disk_gb   = 128
    pci_id    = "0000:05:00"
  }
}

variable "gateway" {
  type    = string
  default = "10.10.10.1"
}

variable "dns_servers" {
  type    = list(string)
  default = ["1.1.1.1"]
}
