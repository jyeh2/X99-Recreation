# Ubuntu 24.04 cloud image, stored once on "local" (content type "import", enabled by host-vfio-setup.sh).
resource "proxmox_download_file" "ubuntu_noble" {
  node_name    = var.node_name
  datastore_id = "local"
  content_type = "import"
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  file_name    = "noble-server-cloudimg-amd64.qcow2"
  overwrite    = false
}

resource "proxmox_virtual_environment_vm" "llm_radeon" {
  name        = "llm-radeon"
  description = "Radeon VII (gfx906) inference VM. Managed by Terraform in homelab-ansible/proxmox/terraform."
  tags        = ["gpu", "terraform"]
  node_name   = var.node_name
  vm_id       = var.radeon_vm.vm_id

  machine = "q35"
  bios    = "ovmf"
  on_boot = true
  started = true

  # Checks the card and its vfio/reset state before every start (proxmox/hookscripts/radeon-vfio.sh).
  hook_script_file_id = "local:snippets/radeon-vfio.sh"

  # The Radeon's BAR0 is 16 GiB with ReBAR. OVMF's default 64-bit MMIO window is too small for it.
  kvm_arguments = "-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536"

  cpu {
    cores = var.radeon_vm.cores
    type  = "host"
  }

  # Passthrough pins all guest RAM, so no ballooning.
  memory {
    dedicated = var.radeon_vm.memory_mb
    floating  = 0
  }

  efi_disk {
    datastore_id      = "local-lvm"
    type              = "4m"
    pre_enrolled_keys = false # Secure Boot off in the guest
  }

  scsi_hardware = "virtio-scsi-single"
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    import_from  = proxmox_download_file.ubuntu_noble.id
    size         = var.radeon_vm.disk_gb
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  hostpci {
    device = "hostpci0"
    id     = var.radeon_vm.pci_id
    pcie   = true
    rombar = true
  }

  # Serial console for `qm terminal 111` when SSH isn't up yet.
  serial_device {}

  operating_system {
    type = "l26"
  }

  # The stock cloud image has no qemu-guest-agent, so don't wait for one.
  agent {
    enabled = false
  }

  initialization {
    datastore_id = "local-lvm"
    ip_config {
      ipv4 {
        address = var.radeon_vm.ip_cidr
        gateway = var.gateway
      }
    }
    dns {
      servers = var.dns_servers
    }
    user_account {
      username = var.guest_user
      keys     = var.ssh_public_keys
    }
  }
}
