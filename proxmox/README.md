# Proxmox on kabangy (planned, 2026-11-13)

Not set up yet; Ansible doesn't manage any of this yet. Diagrams of the plan:
https://claude.ai/artifact/Sn3MREF4zVMGZttmdy2X14 (private)

## Disks

| Disk | System | Notes |
|---|---|---|
| Intel 660p NVMe 512 GB (`nvme0n1`) | Ubuntu 24.04, kernel 7.0 HWE | Unchanged. What everything else in this repo targets. |
| SanDisk Ultra II 1 TB (`sda`) | Proxmox VE 9.2, ext4/LVM (VG `pve`) | Has its own ESP. Pick the system in the firmware boot menu (F7 or F11). |

To go back to Ubuntu, boot the NVMe. Nothing on it changes.

## Install method (no USB stick)

The installer ran in QEMU on Ubuntu with `/dev/sda` as its only disk, so the NVMe was never visible
to it. That leaves two follow-ups:
- The UEFI boot entry ended up in QEMU's NVRAM, so it was added to the real firmware by hand with
  `efibootmgr -c -d /dev/sda -p 2 -l '\EFI\proxmox\shimx64.efi'` (or `grubx64.efi`).
- The installer's network config was for QEMU's virtual NIC. `pve-wifi-setup.sh` replaces it.

## Networking: Wi-Fi + NAT (non-standard, on purpose)

There's no wired connection to the router, so no ethernet cable. Standard Proxmox bridges guests onto
the LAN through a wired port, but a Wi-Fi client can't be bridged: the AP only accepts frames from the
one associated MAC. So:

```
router ── Wi-Fi ── host wlxf0a731dbd1b7 (DHCP from the router)
                     │ NAT (iptables MASQUERADE, post-up on vmbr0)
                  vmbr0 10.10.10.1/24, bridge-ports none (internal only)
                  ├─ llm-radeon 10.10.10.11  VM 111, Radeon VII via VFIO passthrough (Terraform)
                  ├─ llm-cmp    10.10.10.12  LXC, CMP 40HX (/dev/nvidia*)
                  └─ jobs       10.10.10.13  LXC 103, no GPU, Claude job pipeline
```

- Wi-Fi adapter: TP-Link USB, RTL8822BU, driver `rtw88_8822bu`. Firmware is in `pve-firmware`.
  The interface name comes from the MAC, so it's the same as on Ubuntu.
- The Proxmox ISO doesn't ship `wpasupplicant`. `pve-wifi-setup.sh` installs it offline from
  `~/Downloads/proxmox/wifi-debs` (Debian 13 debs, verified against Debian's index).
- Config files: `/etc/network/interfaces` (installer copy saved as `interfaces.installer`) and
  `/etc/wpa_supplicant/wpa_supplicant.conf` (SSID + hashed PSK, mode 600).
- The hostname resolves to `10.10.10.1` in `/etc/hosts`, because Proxmox needs an address that's always
  there. The Wi-Fi DHCP address can change.
- Guests use static IPs, with gateway `10.10.10.1` and DNS `1.1.1.1`.
- **The LAN can't reach guests directly.** Use Tailscale: on the host as a subnet router for
  `10.10.10.0/24`, or in each guest.
- Guest-to-guest traffic (pipeline → llama-server :8080, llama.cpp RPC :50052) never leaves the box.

Getting a wired port later: plug a Wi-Fi bridge (travel router in client mode) into the onboard
Realtek (`enp8s0`). Then set `bridge-ports enp8s0` on vmbr0 and drop the NAT lines.

## Why containers for the GPUs

16 GB of RAM. GPU-passthrough VMs pin all their RAM: all three guests as VMs would need ~18 GB. LXCs
share the host's drivers, so the CMP Gen2 retrain still runs on the host at boot, and the Radeon VII
reset bug doesn't come up. Revisit after adding 2x8 GB RDIMMs.

## Known risks

- cmpunlocker / the NVIDIA kmod have to be rebuilt against the pve kernel (`proxmox-headers-*`).
- The CMP has been dropping off the bus (missing on the 2026-11-13 boot). Check `lspci` first.

## Moving off the NVMe (it gets wiped later and becomes fast model storage)

`pve-migrate-from-nvme.sh` runs on the Proxmox host while the NVMe is still intact.
`pve-wifi-setup.sh` stages it in `/root`. It mounts Ubuntu read-only and copies:
- models → `/srv/models` on the host, bind-mounted read-only at `/models` in llm-radeon (101) and
  llm-cmp (102). One copy serves both.
- cmpunlocker + the NVIDIA .run → `/root/cmpunlocker`, for building the host driver.
- Resume, browser profile, secrets, SSH keys, Claude memory, repos, PDFs → the jobs VM's `/home/james`
  over vmbr0. Same path as before, so `~/.claude/projects/-home-james/memory` still works.

Run it with `DRY_RUN=1` first. After the NVMe is wiped, put a filesystem on it, mount it at
`/srv/models`, and rsync the models back. The containers' `/models` doesn't change.

## llm-radeon VM (Radeon VII passthrough)

Changed 2026-11-14: the Radeon VII goes to its own VM instead of an LXC. The CMP stays an LXC for now.
The Radeon (05:00.0) and its HDMI audio (05:00.1) each sit alone in their own IOMMU groups, so no ACS override is needed.

1. On the host, as root: `bash proxmox/host-vfio-setup.sh`, then reboot. Check that `lspci -nnk -s 05:00.0` says
   `vfio-pci`. The host monitor goes dark after GRUB from now on (see the script header for recovery).
2. On the host: `cd proxmox/terraform`, export `PROXMOX_VE_USERNAME=root@pam` and `PROXMOX_VE_PASSWORD`,
   copy `terraform.tfvars.example` to `terraform.tfvars` (SSH keys), then `terraform init && terraform apply`.
3. From the jobs LXC: `.venv/bin/ansible-playbook radeon.yml` (HWE kernel, ROCm 6.3.3, 200 W cap).

- `hookscripts/radeon-vfio.sh` runs before each start. It refuses to start the VM if the card isn't at the
  `hostpci0` address (bus numbers shift when a card drops off), and puts the card on vfio-pci with
  vendor-reset's `device_specific` reset method.
- Vega 20 has a reset bug. If vendor-reset doesn't build on the pve kernel, the VM starts fine once per host
  boot, but a stop/start may need a host reboot. `journalctl -t radeon-vfio*` shows what happened.
- RAM: 6 GB is reserved for the VM whenever it runs (no ballooning with passthrough).
- Models: the VM can't use the `/srv/models` bind mount. Use virtiofs (directory mapping) or copy them in. Not wired up yet.

## GPU-driven VM startup (`gpu-vms/`)

At boot, `gpu-vm-autostart.service` (installed by `host-vfio-setup.sh`) reads `/etc/gpu-vms.conf`:

```
1002:66af  111  llm-radeon    # Radeon VII
#10de:1f0b  112  llm-cmp      # CMP 40HX (VM not built yet)
```

For each line, if a card with that PCI ID is on the bus, it points the VM's `hostpci0` at the card's
current address and starts the VM. If the card isn't there, the VM stays off. So pulling a card or moving it
to another slot needs no config change. GPU VMs have Proxmox's own `onboot` turned off, and Terraform
ignores `hostpci`/`started` after creation, so the service is the only thing deciding.

- What happened on this boot: `journalctl -b -t gpu-vm-autostart`
- Dry run: `DRY_RUN=1 gpu-vm-autostart`
- New GPU VM: build it (Terraform), then add its line to `/etc/gpu-vms.conf`. Only the first card with a
  given ID is used.
