#!/usr/bin/env bash
# Run ON THE PROXMOX HOST as root, on the first boot (from the console or SSH).
# Safe to rerun: each step checks whether it's already done.
#   1. checks Wi-Fi + internet     2. no-subscription repo, full upgrade
#   3. Tailscale                   4. Radeon VII 200 W cap (same script as on Ubuntu)
#   5. checks the Radeon           6. creates container 101 "llm-radeon" with the Radeon
#                                     shared in, then runs ct-radeon-setup.sh inside it
set -euo pipefail
KIT=/root/kit                         # staged by pve-wifi-setup.sh
CTID=101
CT_IP=10.10.10.11/24
GW=10.10.10.1
RADEON_ID=0x66af

step() { printf '\n== %s ==\n' "$*"; }
[ "$(id -u)" = 0 ] && command -v pct >/dev/null || { echo "run as root on the Proxmox host"; exit 1; }

step "1. Network"
ip -br addr | grep -E '^(wl|vmbr0)' || true
getent hosts deb.debian.org >/dev/null || { echo "No internet. Check: systemctl status networking; journalctl -b -u networking; ip -br link"; exit 1; }
echo "internet OK"

step "2. Package repos + upgrade"
for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
  [ -f "$f" ] && ! grep -q '^Enabled: no' "$f" && echo 'Enabled: no' >> "$f" && echo "disabled $(basename "$f") (needs a paid subscription)"
done
if [ ! -f /etc/apt/sources.list.d/proxmox.sources ]; then
  cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
fi
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
apt-get install -y curl pciutils
newest=$(ls -1 /boot/vmlinuz-*-pve | sed 's#/boot/vmlinuz-##' | sort -V | tail -1)
if [ "$(uname -r)" != "$newest" ]; then
  echo "NOTE: kernel $newest was installed (running $(uname -r)). Reboot after this script finishes."
fi

step "3. Tailscale"
if tailscale status >/dev/null 2>&1; then
  tailscale ip -4
  tailscale set --advertise-routes=10.10.10.0/24 && echo "advertising 10.10.10.0/24: approve it in the Tailscale admin page"
else
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
  echo "Open the login link below on your laptop:"
  tailscale up --ssh --hostname=kabangy-pve --advertise-routes=10.10.10.0/24
  echo "Then approve the 10.10.10.0/24 route in the Tailscale admin page (Machines > kabangy-pve > Edit route settings)."
fi

step "4. Radeon VII power cap"
if [ -f "$KIT/amdgpu-power-cap" ]; then
  install -m 755 "$KIT/amdgpu-power-cap" /usr/local/sbin/amdgpu-power-cap
  install -m 644 "$KIT/amdgpu-power-cap.service" /etc/systemd/system/amdgpu-power-cap.service
  systemctl daemon-reload
  systemctl enable --now amdgpu-power-cap.service
  systemctl restart amdgpu-power-cap.service
else
  echo "no staged power-cap script in $KIT; skipping"
fi

step "5. Radeon VII"
lspci -nn | grep -iE 'vga|display|3d'
DEV=$(grep -l "$RADEON_ID" /sys/bus/pci/drivers/amdgpu/0000:*/device 2>/dev/null | head -1 | xargs -r dirname)
[ -n "$DEV" ] || { echo "Radeon VII not bound to amdgpu. Check lspci / dmesg | grep amdgpu (reseat if it's missing)"; exit 1; }
BDF=$(basename "$DEV")
REND=$(readlink -f "/dev/dri/by-path/pci-$BDF-render")
cap=$(cat "$DEV"/hwmon/hwmon*/power1_cap 2>/dev/null || echo 0)
echo "Radeon at $BDF, render node $REND, /dev/kfd $( [ -e /dev/kfd ] && echo present || echo MISSING ), cap $((cap/1000000)) W"
[ -e /dev/kfd ] && [ -e "$REND" ] || { echo "missing /dev/kfd or the render node; check dmesg | grep -i kfd"; exit 1; }

step "6. Container $CTID llm-radeon"
mkdir -p /srv/models
if ! pct config "$CTID" >/dev/null 2>&1; then
  pveam update >/dev/null
  TPL=$(pveam available --section system | awk '{print $2}' | grep -E '^ubuntu-24\.04-standard_.*amd64' | sort -V | tail -1)
  [ -f "/var/lib/vz/template/cache/$TPL" ] || pveam download local "$TPL"
  pct create "$CTID" "local:vztmpl/$TPL" \
    --hostname llm-radeon --cores 6 --memory 5120 --swap 1024 \
    --rootfs local-lvm:80 \
    --net0 "name=eth0,bridge=vmbr0,ip=$CT_IP,gw=$GW" --nameserver 1.1.1.1 \
    --unprivileged 1 --features nesting=1 --onboot 1
fi
# Device nodes appear at the same path inside; root in the container owns them (uid/gid 0).
pct set "$CTID" --dev0 /dev/kfd --dev1 "$REND" --mp0 /srv/models,mp=/models,ro=1
if pct status "$CTID" | grep -q running; then pct reboot "$CTID"; else pct start "$CTID"; fi
sleep 5
pct exec "$CTID" -- ls -l /dev/kfd "$REND"
pct push "$CTID" "$KIT/ct-radeon-setup.sh" /root/ct-radeon-setup.sh --perms 755
echo "Running the setup inside the container (ROCm download + llama.cpp build, ~20-40 min)..."
pct exec "$CTID" -- /root/ct-radeon-setup.sh

echo
echo "Host + llm-radeon done. Shell into it with: pct enter $CTID"
