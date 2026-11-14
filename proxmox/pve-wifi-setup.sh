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
mount /dev/pve/root "$MNT"
[ -f "$MNT/etc/pve/.version" ] || [ -d "$MNT/etc/pve" ] || { echo "that doesn't look like a Proxmox root"; exit 1; }
for m in proc sys dev dev/pts; do mount --bind "/$m" "$MNT/$m"; done

read -rp  "Wi-Fi network name (SSID): " SSID
read -rsp "Wi-Fi password: " PASS; echo
umask 077
mkdir -p "$MNT/etc/wpa_supplicant"
wpa_passphrase "$SSID" "$PASS" | grep -v '^\s*#psk=' > "$MNT/etc/wpa_supplicant/wpa_supplicant.conf"
unset PASS
umask 022

install -m 755 "$(dirname "$0")/pve-migrate-from-nvme.sh" "$MNT/root/" 2>/dev/null || true
mkdir -p "$MNT/root/wifi-kit"
cp "$KIT"/*.deb "$MNT/root/wifi-kit/"
DEBIAN_FRONTEND=noninteractive chroot "$MNT" sh -c 'dpkg -i /root/wifi-kit/*.deb'
chroot "$MNT" dpkg -s wpasupplicant | grep -q '^Status: install ok installed'

cp -a "$MNT/etc/network/interfaces" "$MNT/etc/network/interfaces.installer"
cat > "$MNT/etc/network/interfaces" <<EOF
# Written by pve-wifi-setup.sh. Installer's original: interfaces.installer
auto lo
iface lo inet loopback

# Host uplink: Wi-Fi client, address from the home router
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
cp -a "$MNT/etc/hosts" "$MNT/etc/hosts.installer"
sed -i "/[[:space:]]${HN%%.*}\([[:space:]]\|$\)/d" "$MNT/etc/hosts"
sed -i "1a ${BR_ADDR%/*} ${HN}.lan ${HN%%.*}" "$MNT/etc/hosts"

echo
echo "Done. Network config:"; grep -nE '^(auto|iface)' "$MNT/etc/network/interfaces"
echo "hosts:"; grep -n "${HN%%.*}" "$MNT/etc/hosts"
