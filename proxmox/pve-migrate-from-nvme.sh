#!/usr/bin/env bash
# Run ON THE PROXMOX HOST (root) after the guests exist and while the Ubuntu NVMe is still intact.
# Opens Ubuntu's disk read-only and copies what's worth keeping:
#   models          -> /srv/models on the host, shared read-only into both LLM containers at /models
#   cmpunlocker     -> /root/cmpunlocker on the host (needed to build the CMP driver)
#   personal stuff  -> james@jobs VM home, over the internal network
# Nothing on the NVMe is modified. DRY_RUN=1 shows what would be copied.
set -euo pipefail

JOBS_IP="${JOBS_IP:-10.10.10.13}"
JOBS_USER="${JOBS_USER:-james}"
RADEON_CT="${RADEON_CT:-101}"
CMP_CT="${CMP_CT:-102}"
SRC=/mnt/ubuntu
H="$SRC/home/james"
MODELS=/srv/models

RSYNC=(rsync -aHAX --info=progress2,stats1)
[ "${DRY_RUN:-0}" = 1 ] && RSYNC+=(--dry-run) && echo "DRY RUN: nothing will be written"

[ "$(id -u)" = 0 ] || { echo "run as root on the Proxmox host"; exit 1; }
command -v pct >/dev/null || { echo "this isn't the Proxmox host"; exit 1; }

cleanup() {
  mountpoint -q "$SRC" && umount "$SRC"
  vgchange -an ubuntu-vg >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 1. open Ubuntu's root read-only (XFS on LVM, VG ubuntu-vg)
vgchange -ay ubuntu-vg >/dev/null
mkdir -p "$SRC"
mount -o ro /dev/ubuntu-vg/ubuntu-lv "$SRC" 2>/dev/null || mount -o ro,norecovery /dev/ubuntu-vg/ubuntu-lv "$SRC"
[ -d "$H/Resume" ] || { echo "can't find /home/james/Resume on the NVMe; stopping"; exit 1; }

# 2. models -> host, shared into both LLM containers
mkdir -p "$MODELS"
"${RSYNC[@]}" "$H/models/qwen3-32b" "$MODELS/"
chmod -R a+rX "$MODELS"
if [ "${DRY_RUN:-0}" != 1 ]; then
  for ct in "$RADEON_CT" "$CMP_CT"; do
    if pct config "$ct" >/dev/null 2>&1; then
      pct config "$ct" | grep -q "^mp0: $MODELS," || pct set "$ct" -mp0 "$MODELS,mp=/models,ro=1"
      echo "container $ct: $MODELS mounted read-only at /models (restart it to see it)"
    else
      echo "container $ct doesn't exist yet; later run: pct set $ct -mp0 $MODELS,mp=/models,ro=1"
    fi
  done
fi

# 3. host-side driver sources
"${RSYNC[@]}" "$H/cmpunlocker" /root/

# 4. personal files -> jobs VM (needs root's SSH key in the VM's ~/.ssh/authorized_keys)
ssh -o BatchMode=yes -o ConnectTimeout=5 "$JOBS_USER@$JOBS_IP" true \
  || { echo "can't SSH to $JOBS_USER@$JOBS_IP. Run: ssh-copy-id $JOBS_USER@$JOBS_IP, then rerun"; exit 1; }
KEEP=(
  Resume .chrome-apply .secrets .ssh .claude .claude.json
  projects Food-Trace holdem-lab interconnect-cap-ml homelab-ansible
  bench-data flashing_rebar cmpunlocker
  Grades_F26.pdf Transcript.pdf main.pdf
  .bashrc .bash_history .gitconfig .config/nvim
)
cd "$H"
present=(); for p in "${KEEP[@]}"; do [ -e "$p" ] && present+=("$p"); done
"${RSYNC[@]}" --relative "${present[@]}" "$JOBS_USER@$JOBS_IP:/home/$JOBS_USER/"

echo
echo "Done. NVMe untouched. Check the jobs VM (Resume pipeline, git status in each repo) before wiping it."
