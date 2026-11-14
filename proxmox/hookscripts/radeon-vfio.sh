#!/bin/bash
# Proxmox hookscript for the llm-radeon VM (Radeon VII, Vega 20, 1002:66af).
# Installed to /var/lib/vz/snippets/radeon-vfio.sh by host-vfio-setup.sh and attached by Terraform.
#
# Proxmox calls it as: radeon-vfio.sh <vmid> <phase>
#   pre-start  : make sure the card is there, on vfio-pci, with vendor-reset's reset method.
#                Exiting non-zero here aborts the VM start, which beats a guest with no GPU.
#   post-stop  : log the card's state, so a stuck card shows up in the journal.
set -u
VMID="$1"
PHASE="$2"
WANT_VENDOR=0x1002
WANT_DEVICE=0x66af

log() { logger -t "radeon-vfio[$VMID]" "$*"; echo "radeon-vfio: $*"; }

# The BDF comes from the VM config, so moving the card means changing one place (Terraform).
# hostpci0: 0000:05:00,pcie=1  ->  0000:05:00.0
bdf_from_config() {
  local raw
  raw=$(qm config "$VMID" | sed -n 's/^hostpci0: \([^,]*\).*/\1/p')
  [ -z "$raw" ] && return 1
  # "05:00" -> "0000:05:00"; "0000:05:00" stays; add .0 if no function was given
  [[ "$raw" =~ ^[0-9a-f]{2}:[0-9a-f]{2} ]] && raw="0000:$raw"
  [[ "$raw" =~ \.[0-7]$ ]] || raw="$raw.0"
  echo "$raw"
}

case "$PHASE" in
  pre-start)
    BDF=$(bdf_from_config) || { log "no hostpci0 in VM config"; exit 1; }
    DEV=/sys/bus/pci/devices/$BDF

    # Bus numbers shift when a card drops off or moves (see the CMP history), so check what's there.
    if [ ! -e "$DEV" ]; then
      log "$BDF not on the bus. Reseat the card or fix hostpci0. Refusing to start."
      exit 1
    fi
    if [ "$(cat "$DEV/vendor")" != "$WANT_VENDOR" ] || [ "$(cat "$DEV/device")" != "$WANT_DEVICE" ]; then
      log "$BDF is $(cat "$DEV/vendor"):$(cat "$DEV/device"), not the Radeon VII. Refusing to start."
      exit 1
    fi

    modprobe vendor-reset 2>/dev/null || log "vendor-reset module not available"
    if grep -qw device_specific "$DEV/reset_method" 2>/dev/null; then
      :
    elif [ -w "$DEV/reset_method" ]; then
      echo device_specific > "$DEV/reset_method" 2>/dev/null \
        && log "reset_method set to device_specific" \
        || log "could not set device_specific (vendor-reset not loaded?). Restarts may need a host reboot."
    fi

    # vfio-pci should already own it (modprobe.d ids=), but take it back if amdgpu got there first.
    for fn in "$DEV" "${DEV%.0}.1"; do
      [ -e "$fn" ] || continue
      drv=$(basename "$(readlink "$fn/driver" 2>/dev/null)" 2>/dev/null)
      if [ "$drv" != "vfio-pci" ]; then
        log "$(basename "$fn") bound to '${drv:-none}', moving it to vfio-pci"
        [ -n "$drv" ] && echo "$(basename "$fn")" > "$fn/driver/unbind"
        echo vfio-pci > "$fn/driver_override"
        echo "$(basename "$fn")" > /sys/bus/pci/drivers_probe
      fi
    done
    log "pre-start OK: $BDF on $(basename "$(readlink "$DEV/driver")"), reset_method=[$(cat "$DEV/reset_method" 2>/dev/null)]"
    ;;

  post-stop)
    BDF=$(bdf_from_config) || exit 0
    DEV=/sys/bus/pci/devices/$BDF
    if [ -e "$DEV" ]; then
      log "post-stop: $BDF power_state=$(cat "$DEV/power_state" 2>/dev/null) driver=$(basename "$(readlink "$DEV/driver" 2>/dev/null)" 2>/dev/null)"
    else
      log "post-stop: $BDF is gone from the bus. The card did not survive the reset; reboot the host."
    fi
    ;;
esac
exit 0
