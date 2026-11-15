#!/bin/bash
# Runs once at boot (gpu-vm-autostart.service), after Proxmox has started its own guests.
# For each line in /etc/gpu-vms.conf:
#   card not on the bus -> leave the VM off
#   card on the bus     -> point the VM's hostpci0 at the card's current address
#                          (bus numbers shift on this board when a card moves or drops off),
#                          then start the VM
# The VM's own hookscript still does the detailed checks (vfio-pci, reset method) before it boots.
# Test without changing anything:  DRY_RUN=1 gpu-vm-autostart
set -u
CONF=${GPU_VMS_CONF:-/etc/gpu-vms.conf}
DRY=${DRY_RUN:-0}

log() { logger -t gpu-vm-autostart "$*"; echo "$*"; }
run() { if [ "$DRY" = 1 ]; then echo "  (dry run) $*"; else "$@" </dev/null; fi; }

[ -r "$CONF" ] || { log "no $CONF, nothing to do"; exit 0; }

while read -r id vmid name _; do
  case "$id" in ''|\#*) continue ;; esac
  name=${name:-vm$vmid}

  bdf=$(lspci -Dn -d "$id" | awk '{print $1}' | head -1)
  if [ -z "$bdf" ]; then
    log "$name: no $id card on the bus, leaving VM $vmid off"
    continue
  fi
  if ! qm status "$vmid" >/dev/null 2>&1 </dev/null; then
    log "$name: card found at $bdf, but VM $vmid doesn't exist yet (terraform apply)"
    continue
  fi

  # hostpci0 looks like "0000:05:00,pcie=1,rombar=1". Keep the options, fix the address.
  # The address is given without a function, so the GPU and its HDMI audio both go to the VM.
  slot=${bdf%.*}
  cur=$(qm config "$vmid" </dev/null | sed -n 's/^hostpci0: //p')
  addr=${cur%%,*}
  opts=${cur#"$addr"}
  [ -n "$cur" ] || opts=",pcie=1"
  [[ $addr =~ ^[0-9a-f]{2}: ]] && addr="0000:$addr"
  if [ "$addr" != "$slot" ]; then
    log "$name: card is at $slot, VM pointed at ${addr:-nothing}; updating hostpci0"
    run qm set "$vmid" --hostpci0 "$slot$opts"
  fi

  if qm status "$vmid" </dev/null | grep -q running; then
    log "$name: VM $vmid already running"
    continue
  fi
  log "$name: card at $bdf, starting VM $vmid"
  run qm start "$vmid" || log "$name: VM $vmid failed to start; see journalctl -b -t 'radeon-vfio[$vmid]' and qm start output above"
done < "$CONF"
exit 0
