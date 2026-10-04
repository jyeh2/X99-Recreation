# homelab-ansible

Ansible for **kabangy**, the X99 home LLM inference server: a Huananzhi X99-BD4 board,
a Xeon E5-2678 v3, Ubuntu 22.04.5 (kernel 5.15), headless, on Tailscale, with an NVIDIA
CMP 40HX mining card that has been unlocked to PCIe Gen2, an 8 GiB BAR1 and full FP16.

The playbook manages itself (`ansible_connection: local`). An Orange Pi Zero (the
Wake-on-LAN relay) is listed in the inventory as a future host but isn't automated yet.

What it does and doesn't cover is listed per item in [SETUP_INVENTORY.md](SETUP_INVENTORY.md).

## Layout

```
ansible.cfg
inventory/hosts.yml                 x99 (localhost); orangepizero commented out
inventory/group_vars/all.yml        login user
inventory/host_vars/x99/main.yml    this machine's values (BDFs, models, switches)
inventory/host_vars/x99/vault.yml   secrets, encrypted (you create it from vault.yml.example)
site.yml
roles/
  base            packages, hostname, timezone, user groups, sysctl, optional Wi-Fi netplan
  tailscale       apt repo, tailscaled, `tailscale up --ssh` when an auth key is given
  nvidia_cmp40hx  610-open driver, package holds, cmpunlocker build, Gen2 retrain unit,
                  idle clock cap unit, read-only verification
  ollama          pinned install, systemd override env, model pulls
  cuda_toolkit    NVIDIA CUDA repo + cuda-toolkit-13-0 (dependency of the two below)
  mistralrs       optional, tag `mistralrs`: rustup + mistral.rs built for sm_75 (~55 min)
  benchmarks      optional, tag `benchmarks`: the bw/flops/llm/load scripts from the unlock post
```

### Switches that are off by default

Anything that needs a reboot, or can't be undone from a running system, is behind a variable:

| Variable | Default | Effect |
|---|---|---|
| `cmp40hx_install_driver` | false | install `nvidia-driver-610-open` 610.57.04 (reboot needed) |
| `cmp40hx_purge_old_drivers` | false | with the above, purge the 570/580-server packages |
| `cmp40hx_build_unlocker` | false | build cmpunlocker and install into `updates/cmpunlocker` (**cold boot** needed) |
| `cmpunlocker_kernel_hook_enabled` | false | rebuild the unlocker automatically for new kernels (recommended, see below) |
| `cmp40hx_unattended_blacklist_kernel` | false | stop unattended-upgrades from installing kernels |
| `base_wifi_enabled` / `base_netplan_apply` | false | write / apply the Wi-Fi netplan |
| tags `mistralrs`, `benchmarks` | never | only run when asked for by tag |

These are on by default because they only act on the next boot and are easy to undo:
the Gen2 retrain unit (`cmp40hx_gen2_retrain_enabled`), apt holds on the 610 packages,
the unattended-upgrades blacklist for `nvidia-*`, and (on x99 only, via host_vars) the
300 MHz idle clock cap that was already on the box.

A routine `site.yml` run restarts ollama once if its override changes. It doesn't touch the
driver, the modules or the PCIe link.

## Bootstrap from a fresh Ubuntu 22.04 install

Do the [manual steps](#manual-steps) first. The BIOS has to be in UEFI mode (CSM off) before
you install Ubuntu, so the installer creates an ESP.

```bash
# 1. Network. The box has only Wi-Fi in practice, and Ubuntu Server's minimal install
#    may not include wpasupplicant (the first time round it was installed offline from a
#    USB SSD: wpasupplicant + libnl-route-3-200 + libpcsclite1 debs). Easiest is to plug in
#    Ethernet for the first run, or set up Wi-Fi in the installer.

# 2. Get this repo and Ansible
sudo apt update && sudo apt install -y git python3-venv
git clone <this repo> ~/homelab-ansible && cd ~/homelab-ansible
python3 -m venv .venv && .venv/bin/pip install ansible-core

# 3. Secrets
cp inventory/host_vars/x99/vault.yml.example inventory/host_vars/x99/vault.yml
$EDITOR inventory/host_vars/x99/vault.yml           # tailscale_authkey, Wi-Fi if wanted
.venv/bin/ansible-vault encrypt inventory/host_vars/x99/vault.yml

# 4. Base system, Tailscale, retrain unit, ollama (no driver yet)
.venv/bin/ansible-playbook site.yml -K --ask-vault-pass

# 5. Driver: 610 open, held
.venv/bin/ansible-playbook site.yml -K --ask-vault-pass --tags nvidia \
    -e cmp40hx_install_driver=true -e cmp40hx_purge_old_drivers=true
sudo reboot
nvidia-smi                                          # stock 610.57.04 should work, Gen1, 64 MiB BAR1

# 6. cmpunlocker (builds for the running kernel and the one /boot/vmlinuz points at)
.venv/bin/ansible-playbook site.yml -K --ask-vault-pass --tags nvidia \
    -e cmp40hx_build_unlocker=true -e cmpunlocker_kernel_hook_enabled=true
sudo shutdown -h now                                # FULL power-off, wait a few seconds, power on

# 7. Check it
.venv/bin/ansible-playbook site.yml -K --tags verify

# 8. Optional
.venv/bin/ansible-playbook site.yml -K --tags benchmarks
.venv/bin/ansible-playbook site.yml -K --tags mistralrs        # ~55 min build
```

Without an encrypted vault, drop `--ask-vault-pass`; the Tailscale role then installs
tailscaled and tells you to run `sudo tailscale up --ssh --hostname=kabangy` yourself.

### Which steps need what kind of restart

| Step | Restart |
|---|---|
| driver install / swap (580 closed to 610 open) | reboot |
| cmpunlocker install (new modules in `updates/cmpunlocker`) | **full power-off and cold boot**. A warm reboot doesn't reset the card |
| kernel update | the unlocker must be rebuilt for the new kernel *before* booting it (hook or `install.sh --no-download`), then cold boot |
| Gen2 retrain unit | none to install; it acts on every boot. To apply now: `sudo cmp40hx-gen2-retrain --stop-services` |
| ollama override | ollama restart (done by the role) |
| BIOS changes | power cycle |

The unlock is volatile: every power cycle returns the card to stock until the patched
driver loads again, and the Gen2 retrain has to happen again after every cold boot. The
`cmp40hx-gen2-retrain.service` unit does the retrain.

## The Gen2 retrain unit

On X99 the patched driver's own retrain fails:

```
NVRM: GPU 0000:03:00.0: CMP40_PCIE_GEN2_V2: RETRAIN_FAIL status=1101
```

The manual fix that worked on 2026-10-02 (from `~/.bash_history` and the screenshot
`~/cmp40hxpcie2.0unlock/after.png`) was:

```bash
sudo systemctl stop ollama nvidia-persistenced
sudo setpci -s 00:02.0 CAP_EXP+10.w=0020:0020
sudo systemctl start nvidia-persistenced ollama
```

The write-up and the memory note give the unmasked form (`=0020`) and say the masked form is
untested. The record shows the opposite: the **masked** form is the one that was run, and it worked.

`/usr/local/sbin/cmp40hx-gen2-retrain` (run by `cmp40hx-gen2-retrain.service`, ordered
`Before=nvidia-persistenced.service ollama.service`) automates it:

1. waits up to `cmp40hx_gen2_retrain_wait` seconds for the driver's `CMP40_PCIE_GEN2_V2` result in the kernel log;
2. exits if the link is already 5 GT/s, or if the driver never set up Gen2 (stock module loaded);
3. writes Retrain Link to the root port (`cmp40hx_root_port_bdf`, default `0000:00:02.0`);
4. logs the resulting speed to the journal (`journalctl -t cmp40hx-gen2-retrain`). It never fails the boot.

`cmp40hx_gen2_retrain_mode: masked` (the default) writes `CAP_EXP+10.w=0020:0020`, which
sets only the Retrain Link bit. `full` writes `CAP_EXP+10.w=0020`, which also clears ASPM and
Common Clock Configuration in Link Control. `full` has never been run on this box, so keep it
as a fallback only.

Find the BDFs on other hardware with:

```bash
lspci -nn -d 10de:1f0b                                                 # the card
basename "$(dirname "$(readlink -f /sys/bus/pci/devices/0000:03:00.0)")"  # its root port
```

## Kernel updates (important)

DKMS rebuilds only the **stock** 610 module for a new kernel, and that module lands in
`updates/dkms/`. Booting a new kernel without rebuilding cmpunlocker for it loses the unlock.
Unattended-upgrades already did this once: on 2026-10-04 it installed 5.15.0-194 and
pointed `/boot/vmlinuz` at it, while `updates/cmpunlocker` only exists for 5.15.0-191.

Pick one:

- **Hook (recommended):** `-e cmpunlocker_kernel_hook_enabled=true` (with
  `cmp40hx_build_unlocker=true` at least once, so `/opt/cmpunlocker` exists) installs
  `/etc/kernel/{postinst.d,header_postinst.d}/zz-cmpunlocker`, which runs
  `KERNEL_UNAME=<new> install.sh --no-download` whenever a kernel or its headers are installed.
- **Manual:** after any kernel update and before rebooting,
  `sudo env KERNEL_UNAME=<new-kver> ./install.sh --no-download` in the cmpunlocker checkout,
  or rerun the playbook with `-e cmp40hx_build_unlocker=true`. It builds for both the running
  kernel and the `/boot/vmlinuz` target.
- **Freeze kernels:** `-e cmp40hx_unattended_blacklist_kernel=true`.

`--tags verify` warns when the next-boot kernel has no patched module.

## Verifying the unlock

`ansible-playbook site.yml -K --tags verify` runs the checks below and prints a report. Add
`-e cmp40hx_verify_strict=true` to fail the run when the unlock is incomplete. By hand:

```bash
modinfo nvidia | grep filename          # .../updates/cmpunlocker/nvidia.ko  (not updates/dkms)
nvidia-smi -q | grep -A3 'BAR1'         # Total : 8192 MiB   (stock: 64 MiB)
sudo lspci -vv -s 03:00.0 | grep LnkSta # Speed 5GT/s, Width x16
sudo lspci -vv -s 00:02.0 | grep LnkSta # 5GT/s (downgraded) is expected: the port can do 8GT/s
sudo dmesg | grep CMP40                 # compute: SS0=0x88888888 SS1=0x00000008 FECS_PLM=0xffffff8f
                                        # CMP40_PCIE_GEN2_V2: RETRAIN_FAIL status=1101 is expected
                                        # on X99; the retrain unit fixes the link afterwards
journalctl -b -t cmp40hx-gen2-retrain   # what the retrain unit did
```

Expected performance (`--tags benchmarks`, then `sudo nvidia-smi -rgc` first if the idle clock
cap is on): pinned H2D ~6.25 GB/s, FP16 GEMM ~54 TFLOPS, qwen3:8b prompt ~1,500 tok/s and
generation ~62 tok/s.

## Rollback to the stock 610 driver

```bash
sudo rm -rf /lib/modules/$(uname -r)/updates/cmpunlocker
sudo depmod -a
sudo update-initramfs -u -k $(uname -r)
sudo systemctl disable cmp40hx-gen2-retrain.service     # or set cmp40hx_gen2_retrain_enabled: false
sudo shutdown -h now                                    # cold boot
```

Repeat the `rm`/`depmod`/`update-initramfs` for every kernel that has an `updates/cmpunlocker`
directory. Turn off `cmpunlocker_kernel_hook_enabled` too, or the hook rebuilds it on the next
kernel. Going back to the 580 closed driver means `apt-mark unhold` on the 610 packages and
installing `nvidia-driver-580-server`.

## Manual steps

These can't be automated and have to be done before (or outside) Ansible.

### Hardware: PCIe AC-coupling capacitors (CMP 40HX)
Mining cards ship with coupling capacitors on only some PCIe lanes. Soldering 0402 100 nF or
220 nF capacitors onto the empty pads brings the card up at x16 instead of x4, which cut model
load time by 46%. Check with `lspci -vv -s 03:00.0 | grep LnkSta` (Width x16).

### BIOS: ReBarDxe mod (Huananzhi X99-BD4, AMI Aptio V 5.11)
Needed for the 8 GiB BAR1 (and for the Arc B580).
1. Dump the full 16 MB flash (`full_backup.bin`) and keep it untouched.
2. Insert `ReBarDxe.ffs` after the last DXE driver with UEFITool 0.28. UEFIPatch found nothing to patch on this board.
3. **Binary-diff against the backup.** UEFITool 0.28 wiped 16 bytes at `0xFFD000` (a GenFv
   jump stub in a pad file of the last volume). Copy those bytes back from the backup.
   The final image is `~/flashing_rebar/patched_image_fixed.rom`, SHA-256
   `3d96d415c5246541c85570982d00b78945c11adb1243fd78be0ac90d9c4f52f0`.
4. Flash **only the BIOS region** with Intel FPT 9.1 from Windows on the board.
5. Set ReBarState in Windows (32 = unlimited is what's set now; `ReBarState` efivar = 0x20).

### BIOS settings
- **Above 4G Decoding: on**
- **CSM: off** (UEFI only). With either one wrong, the system won't POST with the GPU.
- No Wake-on-LAN option exists. Power-on is done by the Orange Pi relay on the PWR_SW header.

### Boot mode
The box was first installed in legacy mode and converted by hand: the LVM PV was shrunk, an
ESP was added as `nvme0n1p4`, and `grub-install --target=x86_64-efi --removable` was run. On a
fresh install, have CSM off before running the Ubuntu installer and none of this is needed.

### Secure Boot
Off. The cmpunlocker modules are unsigned (`module verification failed` taint in dmesg).

### Wake-on-LAN relay (Orange Pi Zero)
`wol_listener.py` + `pcpower` (gpioset on gpiochip0 line 6) + `wol-listener.service` live on
the Pi, which is offline. See the Wake on LAN write-up. Not automated yet.

## Secrets

Nothing secret is in this repo. Put these in `inventory/host_vars/x99/vault.yml` (ansible-vault):

| Variable | Used by |
|---|---|
| `tailscale_authkey` | `tailscale up --auth-key` (only if the node isn't logged in) |
| `base_wifi_ssid`, `base_wifi_psk` | netplan Wi-Fi (only if `base_wifi_enabled`) |

`.gitignore` covers `.venv/`, vault password files and plaintext key files. An encrypted
`vault.yml` is safe to commit.

## Other notes

- **Driver availability.** cmpunlocker needs exactly 610.57.04, and the Ubuntu archive only keeps
  the newest point release in `-updates`. Cache the debs now so a future reinstall still works:
  `mkdir -p ~/debs/nvidia-610 && cd ~/debs/nvidia-610 && apt-get download $(dpkg -l | awk '/^ii/ && /610/ {print $2}' | grep -E 'nvidia|libnvidia')`,
  then use `-e cmp40hx_driver_deb_dir=~/debs/nvidia-610`.
- **CUDA repo.** `cuda_toolkit` installs only `cuda-toolkit-13-0`. Never `apt install cuda` or
  `cuda-drivers` from that repo; they would replace the held Ubuntu driver.
- **Idle clock cap.** `cap-cmp40hx.service` locks the graphics clock at 300 MHz on boot
  (12-15 W idle). Inference is ~10x slower until `sudo nvidia-smi -rgc`. Check with
  `nvidia-smi dmon -s uc`: if pclk reads 300 under load, the cap is still on.
- **Running Ansible in this harness.** If `ansible` errors with "requires blocking IO", run it
  with `</dev/null >out.txt 2>&1` and read the file.
