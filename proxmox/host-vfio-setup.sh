#!/bin/bash
# One-time Proxmox host prep for the llm-radeon VM (Radeon VII passthrough).
# Run on the host as root:  bash host-vfio-setup.sh
# Safe to re-run. Reboot afterwards.
#
# What it does:
#   1. Hands the Radeon VII (1002:66af) and its HDMI audio (1002:ab20) to vfio-pci at boot,
#      so the host's amdgpu never initializes it.
#   2. Builds vendor-reset (DKMS) so the card can reset between VM runs (Vega 20 reset bug).
#   3. Adds iommu=pt and turns off the boot framebuffer (the Radeon is the boot GPU).
#   4. Enables "snippets" and "import" on the local storage and installs the hookscript.
#   5. Installs gpu-vm-autostart: at boot, starts the VM for each GPU that is installed.
#   6. Installs Terraform from HashiCorp's apt repo.
#
# Side effect: the host's monitor output stops after GRUB. The host is headless over Wi-Fi anyway.
# Recovery if something goes wrong: at the GRUB menu press 'e', add
#   modprobe.blacklist=vfio_pci
# to the linux line, and boot. Or pick the Ubuntu NVMe in the firmware boot menu.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
IDS=1002:66af,1002:ab20

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

echo "== Checking the card and IOMMU"
BDF=$(lspci -Dn -d 1002:66af | awk '{print $1}' | head -1)
[ -n "$BDF" ] || { echo "Radeon VII (1002:66af) not on the bus. Reseat it first."; exit 1; }
echo "Radeon VII at $BDF, IOMMU group $(basename "$(readlink /sys/bus/pci/devices/$BDF/iommu_group)")"
ls /sys/bus/pci/devices/$BDF/iommu_group/devices

echo "== vfio-pci at boot"
cat > /etc/modules-load.d/vfio.conf <<EOF
vfio
vfio_iommu_type1
vfio_pci
vendor-reset
EOF
cat > /etc/modprobe.d/vfio-radeon.conf <<EOF
# Radeon VII + its HDMI audio go to vfio-pci for the llm-radeon VM.
options vfio-pci ids=$IDS disable_vga=1
softdep amdgpu pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF

echo "== vendor-reset (DKMS)"
apt-get update
apt-get install -y dkms git build-essential "proxmox-headers-$(uname -r)"
SRC=/usr/src/vendor-reset-0.1.1
if [ ! -d "$SRC" ]; then
  git clone --depth 1 https://github.com/gnif/vendor-reset.git "$SRC"
fi
if ! dkms status vendor-reset | grep -q installed; then
  dkms install "$SRC" || {
    echo
    echo "vendor-reset did not build against $(uname -r). The VM still works, but after it"
    echo "stops, the card may need a host reboot before the VM can start again."
    echo "Continuing without it."
    sed -i '/^vendor-reset$/d' /etc/modules-load.d/vfio.conf
  }
fi
# Kernels since 5.15 need the reset method chosen explicitly; the hookscript also does this.
cat > /etc/udev/rules.d/60-radeon-vendor-reset.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{device}=="0x66af", RUN+="/bin/sh -c 'echo device_specific > /sys$env{DEVPATH}/reset_method'"
EOF

echo "== Kernel command line"
add_arg() {
  grep -q "$1" /etc/default/grub || \
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $1\"/" /etc/default/grub
}
add_arg iommu=pt
add_arg initcall_blacklist=sysfb_init
grep ^GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub
update-grub
update-initramfs -u -k all

echo "== Storage content types and hookscript"
CUR=$(pvesh get /storage/local --output-format json | python3 -c 'import json,sys;print(json.load(sys.stdin).get("content",""))')
NEW=$(echo "$CUR,snippets,import" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd,)
pvesm set local --content "$NEW"
echo "local content: $NEW"
install -d /var/lib/vz/snippets
install -m 0755 "$HERE/hookscripts/radeon-vfio.sh" /var/lib/vz/snippets/radeon-vfio.sh

echo "== GPU -> VM autostart at boot"
install -m 0755 "$HERE/gpu-vms/gpu-vm-autostart.sh" /usr/local/sbin/gpu-vm-autostart
install -m 0644 "$HERE/gpu-vms/gpu-vm-autostart.service" /etc/systemd/system/gpu-vm-autostart.service
# Keep local edits to the table on re-runs.
[ -e /etc/gpu-vms.conf ] || install -m 0644 "$HERE/gpu-vms/gpu-vms.conf" /etc/gpu-vms.conf
systemctl daemon-reload
systemctl enable gpu-vm-autostart.service

echo "== Terraform"
if ! command -v terraform >/dev/null; then
  apt-get install -y gnupg curl
  curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor --yes -o /usr/share/keyrings/hashicorp.gpg
  # HashiCorp ships static Go binaries, so the bookworm repo works on trixie.
  echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com bookworm main" \
    > /etc/apt/sources.list.d/hashicorp.list
  apt-get update
  apt-get install -y terraform
fi
terraform version | head -1

echo
echo "Done. Reboot, then check:"
echo "  lspci -nnk -s ${BDF#0000:}       # 'Kernel driver in use: vfio-pci'"
echo "  cat /sys/bus/pci/devices/$BDF/reset_method   # should list device_specific"
