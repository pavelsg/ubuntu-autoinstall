#!/usr/bin/env bash
# On the Proxmox host. Sets an autoinstall seed URL as SMBIOS system serial.
# It replaces the VM's existing smbios1 settings; preserve UUID/other settings
# manually if those are already configured. No VM disks are modified here.
set -euo pipefail
if (( $# < 3 || $# > 4 )); then
  echo "Usage: $0 VMID GITHUB_OWNER/REPO PROFILE [GIT_REF]" >&2
  echo "Example: $0 120 myorg/ubuntu-proxmox-autoinstall mysql-2disk-uefi main" >&2
  exit 2
fi
VMID="$1" REPO="$2" PROFILE="$3" REF="${4:-main}"
if [[ ! "$VMID" =~ ^[0-9]+$ || ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! "$PROFILE" =~ ^[A-Za-z0-9_-]+$ || ! "$REF" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid parameter" >&2
  exit 2
fi
qm status "$VMID" > /dev/null
if qm config "$VMID" | grep -q '^smbios1:'; then
  echo "ERROR: VM $VMID already has smbios1 settings; back them up and merge manually." >&2
  exit 1
fi
BASE="https://raw.githubusercontent.com/$REPO/$REF/profiles/$PROFILE/"
SEED="ds=nocloud-net;s=$BASE"
SERIAL_B64="$(printf %s "$SEED" | base64 -w0)"
qm set "$VMID" --smbios1 "base64=1,serial=$SERIAL_B64"
printf 'Configured VM %s with NoCloud URL: %s\n' "$VMID" "$BASE"
printf 'Cloud-init requires early network/DHCP to fetch profile before installer network screen.\n'
printf 'Start the VM from an Ubuntu Server live ISO. Installer may request disk-erasure confirmation.\n'
