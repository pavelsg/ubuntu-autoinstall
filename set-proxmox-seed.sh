#!/usr/bin/env bash
# On the Proxmox host. Sets an autoinstall seed URL as SMBIOS system serial.
# Selects the bios/uefi profile directory from the VM's firmware setting.
# Preserves existing SMBIOS fields while adding/updating a NoCloud serial.
# No VM disks are modified here.
set -euo pipefail
if (( $# < 3 || $# > 4 )); then
  echo "Usage: $0 VMID GITHUB_OWNER/REPO PROFILE [GIT_REF]" >&2
  echo "Examples:" >&2
  echo "  $0 120 pavelsg/ubuntu-autoinstall single-disk main" >&2
  echo "  $0 120 pavelsg/ubuntu-autoinstall single-disk-noipv6 main" >&2
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
BASE="https://raw.githubusercontent.com/$REPO/$REF/profiles/$FIRMWARE/$PROFILE/"
SEED="ds=nocloud-net;s=$BASE"
SERIAL_B64="$(printf %s "$SEED" | base64 | tr -d '\n')"
SMBIOS="$(printf '%s\n' "$VM_CONFIG" | sed -n 's/^smbios1: //p')"
IFS=, read -r -a SMBIOS_FIELDS <<< "${SMBIOS:-base64=0}"
ENCODED=0
SEEN_KEYS=,
# base64 applies to every SMBIOS string field, but never to the UUID.
# Validate first so an unknown field cannot be silently dropped or reinterpreted.
for FIELD in "${SMBIOS_FIELDS[@]}"; do
  KEY="${FIELD%%=*}"
  if [[ "$FIELD" != *=* || "$SEEN_KEYS" == *",$KEY,"* ]]; then
    echo "ERROR: Malformed or duplicate SMBIOS field: $KEY" >&2
    exit 1
  fi
  SEEN_KEYS+="$KEY,"
  case "$KEY" in
    base64)
      ENCODED="${FIELD#*=}"
      if [[ "$ENCODED" != 0 && "$ENCODED" != 1 ]]; then
        echo "ERROR: Unsupported SMBIOS base64 flag: $ENCODED" >&2
        exit 1
      fi
      ;;
    uuid|serial|manufacturer|product|version|sku|family) ;;
    *) echo "ERROR: Unsupported SMBIOS field: $KEY" >&2; exit 1 ;;
  esac
done
MERGED_SMBIOS="base64=1,serial=$SERIAL_B64"
for FIELD in "${SMBIOS_FIELDS[@]}"; do
  KEY="${FIELD%%=*}"
  VALUE="${FIELD#*=}"
  case "$KEY" in
    base64) continue ;;
    uuid) MERGED_SMBIOS+=",$FIELD"; continue ;;
  esac
  if [[ "$ENCODED" == 1 ]]; then
    if ! DECODED="$(printf %s "$VALUE" | base64 -d)"; then
      echo "ERROR: Invalid base64 in SMBIOS field: $KEY" >&2
      exit 1
    fi
  else
    DECODED="$VALUE"
  fi
  if [[ "$KEY" == serial ]]; then
    case "$DECODED" in
      ""|ds=nocloud\;*|ds=nocloud-net\;*) continue ;;
      *) echo "ERROR: VM $VMID has an unrelated SMBIOS serial; merge manually to avoid losing it." >&2; exit 1 ;;
    esac
  fi
  if [[ "$ENCODED" != 1 ]]; then
    VALUE="$(printf %s "$VALUE" | base64 | tr -d '\n')"
  fi
  MERGED_SMBIOS+=",$KEY=$VALUE"
done
qm set "$VMID" --smbios1 "$MERGED_SMBIOS"
printf 'Detected VM firmware: %s\n' "$FIRMWARE"
printf 'Configured VM %s with NoCloud URL: %s\n' "$VMID" "$BASE"
printf 'Cloud-init requires early network/DHCP to fetch profile before installer network screen.\n'
printf 'Start the VM from an Ubuntu Server live ISO. Installer may request disk-erasure confirmation.\n'
