# Setup inventory: kabangy (X99)

Everything found about how this machine was set up, grouped by area. Sources: `~/.bash_history`
(1,661 lines), Claude Code prompt history and session transcripts, the project folders, the
write-ups in `~/projects/posts/`, the memory note, and a read-only look at the system on
2026-10-04. No secrets were found in the shell history. Nothing secret was copied here.

Status key:
- **automated**: a role in this repo does it
- **manual**: has to be done by hand (hardware, firmware, or one-time decisions); see README
- **obsolete**: done once, then abandoned or replaced; deliberately not automated
- **not automated**: still in use, but personal/dev environment, left out on purpose

## Hardware and firmware

| Item | Status | Notes |
|---|---|---|
| Huananzhi X99-BD4, Xeon E5-2678 v3 (12C/24T) | manual | |
| RAM: 15 GiB (write-ups corrected 2026-10-04; earlier drafts said 7.7 GB) (ReBar post says 16 GB DDR4-2133 ECC RDIMM) | manual | upgraded at some point; see questions |
| CMP 40HX (TU106 10de:1f0b, VBIOS 90.06.67.00.04) at 03:00.0 on root port 00:02.0 (8086:2f04) | manual | second physical slot, the first full x16 one |
| Second CMP 40HX died | obsolete | posts and resume updated for one card |
| PCIe AC-coupling capacitor solder mod (x4 to x16, -46% load time) | manual | |
| ReBarDxe inserted into BIOS 5.11, UEFITool 16-byte pad-file fix, flashed with Intel FPT 9.1 | manual | `~/flashing_rebar/patched_image_fixed.rom`; on 2026-10-02 the board already had it (ReBarState 0x20) |
| BIOS: Above 4G Decoding on, CSM off | manual | |
| Arc B580 in this board (ReBar testing, Superposition 9182) | obsolete | Windows-side; not in the box now |
| V100 alongside the CMP (discussed) | obsolete | only discussed |
| GPU in 2nd/3rd slot not detected (2026-09-25 debugging) | obsolete | slot diagnosis; resolved by slot choice |
| Wake-on-LAN: Orange Pi Zero + relay on PWR_SW, `wol_listener.py`, `pcpower`, `wol-listener.service` | manual | lives on the Pi; inventory has a commented `orangepizero` host for later |

## OS install, boot, storage

| Item | Status | Notes |
|---|---|---|
| Ubuntu 22.04.5 server, LVM root (xfs), /boot ext4, 4 GB /swap.img | manual | installer defaults |
| Legacy to UEFI conversion: `pvresize` shrink, `parted resizepart 3`, new ESP `nvme0n1p4` (vfat), fstab entry, `grub-efi-amd64(-signed) shim-signed`, `grub-install --removable` and `--no-nvram`, `update-grub` | manual | one-off; a fresh install with CSM off makes an ESP itself |
| Secure Boot off (cmpunlocker modules unsigned) | manual | `mokutil --sb-state`: disabled, Setup Mode |
| Hostname `kabangy`, timezone Etc/UTC | automated | `base` |
| `/etc/default/grub`: stock (`GRUB_TIMEOUT=0`, empty cmdline) | not automated | nothing to change |
| `nvidia_drm modeset=1` (`/etc/modprobe.d/nvidia-graphics-drivers-kms.conf`) | automated (by package) | shipped by the 610 driver |
| `grant-claude-sudo.sh` / `revoke-claude-sudo.sh` (temporary `/etc/sudoers.d/claude-diag`) | obsolete | revoked; `/etc/sudoers.d` has only README |

## Networking and remote access

| Item | Status | Notes |
|---|---|---|
| Wi-Fi uplink `wls2` via netplan + wpa_supplicant (enp6s0 unplugged) | automated (opt-in) | `base_wifi_enabled`; SSID/PSK via vault. Current config is in `/etc/netplan/50-cloud-init.yaml` (0600, not read) |
| `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` = `network: {config: disabled}` | automated (opt-in) | part of the Wi-Fi tasks |
| wpasupplicant + libnl-route-3-200 + libssl1.1 installed offline from a USB SSD with `dpkg -i` | manual | bootstrap problem: no network without it. `wpasupplicant` is in `base_packages` |
| `netplan try/apply`, rfkill, wpa_supplicant debugging | obsolete | troubleshooting |
| OpenSSH server enabled; `~/.ssh` has authorized_keys and a github key | automated (sshd) / manual (keys) | keys are secrets, not copied |
| Tailscale via `install.sh`, then the apt repo; `tailscale up`; `tailscale set --ssh` | automated | `tailscale`; auth key via vault. The node shows as `kabangy-1` in the tailnet (stale `kabangy` node?) |
| UFW enabled (unit enabled; rules not readable without root) | not automated | see questions |

## NVIDIA driver and CMP 40HX unlock

| Item | Status | Notes |
|---|---|---|
| `nvidia-driver-570-server` + dkms, then `580-server` (580.173.02, upgraded to 580.178.04) | obsolete | replaced by 610 open on 2026-10-02 |
| `nvidia-firmware-580-server-580.178.04` left over (autoremovable) | obsolete | `apt autoremove` candidate |
| `nvidia-driver-610-open` + `nvidia-dkms-610-open` 610.57.04-0ubuntu0.22.04.3 (jammy-updates/multiverse) | automated (opt-in) | `cmp40hx_install_driver` |
| apt-mark hold on 610 packages | automated | **the write-up says they were held, but `apt-mark showhold` is empty now** |
| unattended-upgrades blacklist for `nvidia-*` | automated | new; jammy-security carries the 610 packages, so u-u could upgrade the userspace |
| cmpunlocker v2.0.1 (`e4b4d46`): `git clone`, `sudo ./install.sh` (download + SHA-256 + 3 patches + build), modules in `/lib/modules/5.15.0-191-generic/updates/cmpunlocker/` | automated (opt-in) | `cmp40hx_build_unlocker`; pinned commit and source SHA-256 |
| Full power-off after install | manual | printed by the role |
| `modinfo nvidia` → `updates/cmpunlocker/nvidia.ko` (stock dkms copy sits in `updates/dkms/`) | automated | `--tags verify` |
| Code review of cmpunlocker for malicious code (user asked) | obsolete | one-off |
| Gen2 retrain: driver logs `RETRAIN_FAIL status=1101`; fix `setpci -s 00:02.0 CAP_EXP+10.w=0020:0020` with ollama + persistenced stopped | automated | `cmp40hx-gen2-retrain.service` (default `mode: masked`), ordered before ollama/persistenced |
| **Discrepancy:** the write-up and memory note say the unmasked `=0020` was used and masked is untested. Bash history (line 1646) and `~/cmp40hxpcie2.0unlock/after.png` show the **masked** `=0020:0020` was run and gave 5GT/s x16 | needs fixing in the post | unmasked kept as `mode: full`, never run |
| `tools/cmp40hx-driver-reprobe-gen2.sh --confirm-driver-reprobe` (upstream recovery via unbind/rebind) | obsolete | tried first; the root port retrain replaced it. Upstream also ships a `.service` for it, not used |
| `--pcie-diagnostic` patch variant, `cmp_glcore_patch` (Vulkan userspace), Windows/UEFI unlocker | obsolete / not used | headless Linux box |
| Rebuild after kernel update: `install.sh --no-download` | automated (opt-in) | builds for the running and next-boot kernels; kernel hook `cmpunlocker_kernel_hook_enabled` |
| **Kernel 5.15.0-194 installed by unattended-upgrades 2026-10-04 17:33; `/boot/vmlinuz` → 194; no `updates/cmpunlocker` for 194** | needs action | the next boot loses the unlock; see questions |
| `cap-cmp40hx.service` + `/usr/local/bin/cap_cmp40hx.sh`: persistence mode, lock graphics clock at 300 MHz, motd/wall reminder | automated | `cmp40hx_idle_clock_cap_enabled` (true for x99). **The script has two copies pasted into one file; the unit ends `failed` (syntax error, status=2) after applying the lock.** The role installs a clean copy |
| `nvidia-smi -rgc` before inference; `-lgc 1500,2100` once for benchmarks | manual | operational habit |
| `nvidia-smi -pm 1`, `-lmc 405,405`, `--gpu-reset`, many `-q -d ...` queries | obsolete | experiments and diagnostics |
| nvidia-persistenced (static unit, started by the driver package) | automated (by package) | |
| `gpu-manager`, `nvidia-suspend/resume/hibernate` enabled | automated (by package) | |
| nvtop | automated | `base` |

## CUDA and toolchains

| Item | Status | Notes |
|---|---|---|
| `cuda-keyring_1.1-1` + `cuda-toolkit-13-0` (13.0.3); PATH/CUDA_HOME lines in `~/.bashrc` | automated | `cuda_toolkit` (`/etc/profile.d/cuda.sh` instead of .bashrc) |
| Nsight (nsys in /usr/local/bin) | automated (by toolkit) | |
| rustup (stable) in `~/.cargo` | automated | `mistralrs` |
| Miniconda in `~/miniconda3`, `conda create -n torch-env python=3.11`; also `python3 -m venv ~/torch-env` + `pip install torch numpy`; `~/docs/bench/test.py` tensor bench | not automated | early experiments, superseded by the CUDA benches; see questions |
| Go 1.25.0 in `/usr/local/go` (for coursework `a2-dnote`) | not automated | coursework |
| Neovim (tarball in `~/.local/opt`), LazyVim starter, `coder/claudecode.nvim`, tree-sitter-cli | not automated | personal editor setup |
| Claude Code (native installer, `~/.local/bin/claude`) | not automated | personal; was removed and reinstalled once |
| jq, unzip, tmux, git, build-essential | automated | `base` |

## Inference stack

| Item | Status | Notes |
|---|---|---|
| Ollama via `curl -fsSL https://ollama.com/install.sh \| sh` (0.32.5 now, `/usr/local/bin/ollama`, user `ollama` in video/render) | automated | `ollama`, version pinned |
| `ollama.service` has a PATH baked from james's shell (by install.sh) | automated (by install.sh) | harmless |
| `OLLAMA_MAX_LOADED_MODELS=1` | automated | **recommended in the extraction write-up after an OOM kill, but not actually set on the box.** Now in a drop-in |
| Ollama ordered after the Gen2 retrain | automated | drop-in `After=` |
| Models: gemma4:e4b (daily), qwen3:8b, qwen3.5:4b, qwen2.5:3b (benchmarks) | automated | `ollama_models` |
| GGUFs in `~/models` (gemma-4-E4B-it Q4_K_M + mmproj-F16, Qwen3.5-4B, ollama exports) for mistral.rs | manual | downloaded from HF; re-download or copy |
| mistral.rs: `cargo install mistralrs-cli` (0.8.1 crate, afq.cu link bug), candle `compatibility.cuh` hand patch | obsolete | replaced by building master |
| mistral.rs master (0.9.4, `2370966`) in `~/src/mistral.rs`, branch `gemma4-ple-cpu` (`37d5d35`), built with `CUDA_COMPUTE_CAP=75 cargo build --release --locked --features cuda -p mistralrs-cli -j 8` (55m40s) | automated (tag) | `mistralrs`; the patch comes from `kvsnap/patches` |
| `run_mistralrs.sh` (port 8090, `MISTRALRS_GEMMA4_PLE_CPU=1`, `--pa-context-len 18432`) | not automated | lives in the kvsnap / KVCaching-Prompt repos |
| llama-server (ollama's bundled binary) on :8089 for kvsnap slot snapshots | obsolete | experiment |

## Projects and benchmarks (data, not system config)

| Item | Status | Notes |
|---|---|---|
| `~/flashing_rebar/bench`: `bw.cu`, `flops.cu` (nvcc, -lcublas), `llm.sh`, `load.sh`, `baseline_gen1.txt`, `after_unlock_gen2.txt` | automated (tag) | `benchmarks` copies and compiles to `~/bench/cmp40hx` |
| `~/bench-data` + `~/bench-extract` (job-posting extraction benchmark, 78 docs) | not automated | project data |
| `~/kvsnap` (local git, no remote) and `~/KVCaching-Prompt` (github jyeh2/KVCaching-Prompt) | not automated | project repos |
| `~/cmp40hxpcie2.0unlock` screenshots | not automated | write-up assets |
| `~/projects` (github jyeh2/projects, posts) | not automated | |

## Leftovers worth cleaning up (not done; read-only task)

- `nvidia-firmware-580-server-580.178.04`, `grub-pc-bin` are autoremovable.
- Old kernels 186/187 still have `/lib/modules` dirs.
- `lxd` snap, `open-vm-tools`, ModemManager and multipathd are installer defaults that a headless bare-metal box doesn't need.
