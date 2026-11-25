#!/usr/bin/env bash
# Run from Ubuntu (sudo) AFTER the Proxmox installer has finished writing to the SanDisk (/dev/sda).
# Installs wpasupplicant offline into the Proxmox root and writes a Wi-Fi + NAT network config:
#   host on Wi-Fi via DHCP; guests on vmbr0 10.10.10.0/24 (no physical port), NATed out over Wi-Fi.
set -euo pipefail

WIFI_IF="${WIFI_IF:-wlxf0a731dbd1b7}"     # TP-Link RTL8822BU; name is derived from its MAC, same under Proxmox
BR_ADDR="10.10.10.1/24"
BR_NET="10.10.10.0/24"
KIT="${KIT:-/home/james/Downloads/proxmox/wifi-debs}"   # offline .debs: wpasupplicant iw libnl-genl-3-200 libpcsclite1 libreadline8t64 readline-common (Debian 13)
MNT=/mnt/pve
HERE_TS="${HERE_TS:-/home/james/Downloads/proxmox/tailscale-deb}"   # tailscale_1.104.7_amd64.deb (Debian 13, sha256 verified)

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
model=$(lsblk -dno MODEL /dev/sda | xargs)
[ "$model" = "SanDisk Ultra II" ] || { echo "/dev/sda is '$model', expected SanDisk Ultra II; stopping"; exit 1; }
ls "$KIT"/wpasupplicant_*.deb >/dev/null

cleanup() {
  for m in dev/pts dev sys proc; do mountpoint -q "$MNT/$m" && umount "$MNT/$m"; done
  mountpoint -q "$MNT" && umount "$MNT"
  vgchange -an pve >/dev/null 2>&1 || true
}
trap cleanup EXIT

vgchange -ay pve >/dev/null
mkdir -p "$MNT"
for m in dev/pts dev sys proc; do mountpoint -q "$MNT/$m" && umount "$MNT/$m"; done
mountpoint -q "$MNT" && umount "$MNT"
mount /dev/pve/root "$MNT"
[ -f "$MNT/etc/pve/.version" ] || [ -d "$MNT/etc/pve" ] || { echo "that doesn't look like a Proxmox root"; exit 1; }
for m in proc sys dev dev/pts; do mount --bind "/$m" "$MNT/$m"; done

umask 077
mkdir -p "$MNT/etc/wpa_supplicant"
UBU_WPA="/run/netplan/wpa-$WIFI_IF.conf"   # the config Ubuntu is connected with right now
if [ -s "$UBU_WPA" ]; then
  cp "$UBU_WPA" "$MNT/etc/wpa_supplicant/wpa_supplicant.conf"
  echo "Wi-Fi: copied Ubuntu's working config ($(grep -m1 -o 'key_mgmt=[A-Z0-9-]*' "$UBU_WPA" || echo 'key_mgmt default'))"
else
  read -rp  "Wi-Fi network name (SSID): " SSID
  read -rsp "Wi-Fi password: " PASS; echo
  wpa_passphrase "$SSID" "$PASS" | grep -v '^\s*#psk=' > "$MNT/etc/wpa_supplicant/wpa_supplicant.conf"
  unset PASS
fi
umask 022

# Tailscale: carry this machine's identity over, so Proxmox comes up at the same Tailscale address.
# Safe because Ubuntu and Proxmox run on the same hardware and never at the same time.
TS_DEB=$(ls "$HERE_TS"/tailscale_*_amd64.deb 2>/dev/null | head -1 || true)
read -rp "Copy Tailscale identity so Proxmox is reachable at $(tailscale ip -4 2>/dev/null | head -1)? [Y/n] " TSA
if [ -n "$TS_DEB" ] && [ "${TSA:-y}" != n ] && [ -f /var/lib/tailscale/tailscaled.state ]; then
  cp "$TS_DEB" "$MNT/root/"
  DEBIAN_FRONTEND=noninteractive chroot "$MNT" dpkg -i "/root/$(basename "$TS_DEB")"
  mkdir -p "$MNT/var/lib/tailscale"
  cp -a /var/lib/tailscale/. "$MNT/var/lib/tailscale/"
  chroot "$MNT" systemctl enable tailscaled >/dev/null 2>&1 || true
  echo "Tailscale: installed and identity copied (reach Proxmox at the same Tailscale address/name)"
else
  echo "Tailscale: skipped. The first boot needs a monitor on the Radeon VII."
fi

# Stage the first-boot kit: scripts for /root, plus Ubuntu's working Radeon power-cap script/unit.
HERE="$(cd "$(dirname "$0")" && pwd)"
install -d "$MNT/root/kit"
for f in pve-first-boot.sh pve-migrate-from-nvme.sh; do install -m 755 "$HERE/$f" "$MNT/root/"; done
install -m 755 "$HERE/ct-radeon-setup.sh" "$MNT/root/kit/"
install -m 755 /usr/local/sbin/amdgpu-power-cap "$MNT/root/kit/"
install -m 644 /etc/systemd/system/amdgpu-power-cap.service "$MNT/root/kit/"
mkdir -p "$MNT/root/wifi-kit"
cp "$KIT"/*.deb "$MNT/root/wifi-kit/"
DEBIAN_FRONTEND=noninteractive chroot "$MNT" sh -c 'dpkg -i /root/wifi-kit/*.deb'
chroot "$MNT" dpkg -s wpasupplicant | grep -q '^Status: install ok installed'

# The installer may have pinned QEMU's virtual NIC (MAC 52:54:00:12:34:56) as nic0. It doesn't exist on the real box.
for d in "$MNT/usr/local/lib/systemd/network" "$MNT/etc/systemd/network"; do
  [ -d "$d" ] || continue
  for f in "$d"/*.link; do
    [ -f "$f" ] && grep -qi '52:54:00:12:34:56' "$f" || continue
    mv "$f" "$f.qemu-disabled" && echo "disabled QEMU NIC pin: ${f#$MNT}"
  done
done
[ -e "$MNT/etc/network/interfaces.installer" ] || cp -a "$MNT/etc/network/interfaces" "$MNT/etc/network/interfaces.installer"
cat > "$MNT/etc/network/interfaces" <<EOF
# Written by pve-wifi-setup.sh. Installer's original: interfaces.installer
auto lo
iface lo inet loopback

# Host uplink: Wi-Fi client (apartment Wi-Fi, clients isolated), address via DHCP
auto $WIFI_IF
iface $WIFI_IF inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

# Guest network: internal bridge, NATed out over Wi-Fi (Wi-Fi can't be bridged)
auto vmbr0
iface vmbr0 inet static
    address $BR_ADDR
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   sysctl -w net.ipv4.ip_forward=1
    post-up   iptables -t nat -A POSTROUTING -s '$BR_NET' -o $WIFI_IF -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '$BR_NET' -o $WIFI_IF -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1

source /etc/network/interfaces.d/*
EOF

# Proxmox needs its hostname to resolve to an address that always exists: use the bridge.
HN=$(cat "$MNT/etc/hostname")
[ -e "$MNT/etc/hosts.installer" ] || cp -a "$MNT/etc/hosts" "$MNT/etc/hosts.installer"
sed -i "/[[:space:]]${HN%%.*}\([[:space:]]\|$\)/d" "$MNT/etc/hosts"
sed -i "1a ${BR_ADDR%/*} ${HN}.lan ${HN%%.*}" "$MNT/etc/hosts"

echo
echo "Done. Network config:"; grep -nE '^(auto|iface)' "$MNT/etc/network/interfaces"
echo "hosts:"; grep -n "${HN%%.*}" "$MNT/etc/hosts"
