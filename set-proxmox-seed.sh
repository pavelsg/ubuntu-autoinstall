#!/usr/bin/env bash
# On the Proxmox host. Sets an autoinstall seed URL as SMBIOS system serial.
# Selects the bios/uefi profile directory from the VM's firmware setting.
# Existing smbios1 settings must be merged manually. No VM disks are modified here.
set -euo pipefail
if (( $# < 3 || $# > 4 )); then
  echo "Usage: $0 VMID GITHUB_OWNER/REPO PROFILE [GIT_REF]" >&2
  echo "Examples:" >&2
  echo "  $0 120 pavelsg/ubuntu-autoinstall single-disk main" >&2
  echo "  $0 120 pavelsg/ubuntu-autoinstall mysql-2disk main" >&2
  echo "  $0 120 pavelsg/ubuntu-autoinstall mysql-2disk-noipv6 main" >&2
  exit 2
fi
VMID="$1" REPO="$2" PROFILE="$3" REF="${4:-main}"
if [[ ! "$VMID" =~ ^[0-9]+$ || ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! "$PROFILE" =~ ^[A-Za-z0-9_-]+$ || ! "$REF" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid parameter" >&2
  exit 2
fi
qm status "$VMID" > /dev/null
VM_CONFIG="$(qm config "$VMID")"
# An omitted bios option uses Proxmox's SeaBIOS default.
BIOS="$(printf '%s\n' "$VM_CONFIG" | awk '$1 == "bios:" {print $2}')"
case "$BIOS" in
  ""|seabios) FIRMWARE=bios ;;
  ovmf) FIRMWARE=uefi ;;
  *) echo "ERROR: Unsupported VM firmware: $BIOS" >&2; exit 1 ;;
esac
if printf '%s\n' "$VM_CONFIG" | grep -q '^smbios1:'; then
  echo "ERROR: VM $VMID already has smbios1 settings; back them up and merge manually." >&2
  exit 1
fi
BASE="https://raw.githubusercontent.com/$REPO/$REF/profiles/$FIRMWARE/$PROFILE/"
SEED="ds=nocloud-net;s=$BASE"
SERIAL_B64="$(printf %s "$SEED" | base64 | tr -d '\n')"
qm set "$VMID" --smbios1 "base64=1,serial=$SERIAL_B64"
printf 'Detected VM firmware: %s\n' "$FIRMWARE"
printf 'Configured VM %s with NoCloud URL: %s\n' "$VMID" "$BASE"
printf 'Cloud-init requires early network/DHCP to fetch profile before installer network screen.\n'
printf 'Start the VM from an Ubuntu Server live ISO. Installer may request disk-erasure confirmation.\n'
