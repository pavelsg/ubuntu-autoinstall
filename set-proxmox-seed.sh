#!/usr/bin/env bash
# On the Proxmox host. Configures a web seed or a local static-network seed ISO.
# Selects the bios/uefi profile directory from the VM's firmware setting.
# Preserves existing SMBIOS fields while adding/updating a NoCloud serial.
# The local mode attaches a CD-ROM; target disks are never modified here.
set -euo pipefail

# Print the supported invocation and defaults to stderr.
usage() {
  echo "Usage: $0 VMID GITHUB_OWNER/REPO PROFILE [GIT_REF] [OPTIONS]" >&2
  echo "Static seed ISO: --ip IPv4/PREFIX --gateway IPv4 [--dns IPv4]" >&2
  echo "  --dns defaults to gateway; --interface defaults to net0." >&2
  echo "  --storage defaults to local; --seed-slot selects a free ide0..3 or sata0..5." >&2
  echo "Examples:" >&2
  echo "  $0 120 pavelsg/ubuntu-autoinstall single-disk main" >&2
  echo "  $0 103 pavelsg/ubuntu-autoinstall single-disk-noipv6 main --ip 10.0.0.34/24 --gateway 10.0.0.1" >&2
  echo "  $0 120 pavelsg/ubuntu-autoinstall mysql-2disk main" >&2
}

# Stop before changing VM configuration when a prerequisite is not met.
# Args: a human-readable error message.
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == --help ]]; then
  usage
  exit 0
fi
if (( $# < 3 )); then
  usage
  exit 2
fi
VMID="$1" REPO="$2" PROFILE="$3" REF=main
shift 3
if (( $# )) && [[ "$1" != --* ]]; then
  REF="$1"
  shift
fi
IP="" GATEWAY="" DNS="" INTERFACE=net0 STORAGE=local SEED_SLOT=""
STATIC_MODE=0
SEEN_OPTIONS=,
while (( $# )); do
  OPTION="$1"
  case "$OPTION" in
    --ip|--gateway|--dns|--interface|--storage|--seed-slot) ;;
    *) echo "Unknown option: $OPTION" >&2; usage; exit 2 ;;
  esac
  if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
    echo "Missing value for $OPTION" >&2
    exit 2
  fi
  if [[ "$SEEN_OPTIONS" == *",$OPTION,"* ]]; then
    echo "Duplicate option: $OPTION" >&2
    exit 2
  fi
  SEEN_OPTIONS+="$OPTION,"
  STATIC_MODE=1
  case "$OPTION" in
    --ip) IP="$2" ;;
    --gateway) GATEWAY="$2" ;;
    --dns) DNS="$2" ;;
    --interface) INTERFACE="$2" ;;
    --storage) STORAGE="$2" ;;
    --seed-slot) SEED_SLOT="$2" ;;
  esac
  shift 2
done
if [[ ! "$VMID" =~ ^[0-9]+$ || ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! "$PROFILE" =~ ^[A-Za-z0-9_-]+$ || ! "$REF" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid parameter" >&2
  exit 2
fi
if (( STATIC_MODE )); then
  [[ -n "$IP" && -n "$GATEWAY" ]] || die "Static mode requires both --ip and --gateway."
  [[ "$INTERFACE" =~ ^net[0-9]+$ ]] || die "--interface must name a Proxmox NIC, such as net0."
  [[ "$STORAGE" =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]] || die "Invalid storage identifier."
  [[ -z "$SEED_SLOT" || "$SEED_SLOT" =~ ^(ide[0-3]|sata[0-5])$ ]] || die "--seed-slot must be ide0..3 or sata0..5."
  DNS="${DNS:-$GATEWAY}"
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  HELPER="$SCRIPT_DIR/prepare_local_seed.pl"
  [[ -f "$HELPER" ]] || die "Static mode needs prepare_local_seed.pl beside this script; copy the full repository."
  for COMMAND in perl curl genisoimage pvesm pvesh; do
    command -v "$COMMAND" > /dev/null || die "Missing $COMMAND. Run on a Proxmox host with curl and genisoimage installed."
  done
  perl -MYAML::XS=0.84 -MNetAddr::IP -MJSON::PP -e 1 2>/dev/null || die "Static mode needs Proxmox's Perl modules: YAML::XS >= 0.84, NetAddr::IP, JSON::PP (available on Proxmox VE 8+)."
  perl "$HELPER" validate-network --ip "$IP" --gateway "$GATEWAY" --dns "$DNS"
fi
VM_STATUS="$(qm status "$VMID")"
if (( STATIC_MODE )) && [[ "$VM_STATUS" != "status: stopped" ]]; then
  die "VM $VMID must be stopped before attaching a local seed ISO."
fi
if (( STATIC_MODE )); then
  # qm's text output omits the digest. Read it before the configuration snapshot
  # so qm set can reject any concurrent change under Proxmox's own config lock.
  CONFIG_JSON="$(pvesh get "/nodes/$(hostname -s)/qemu/$VMID/config" --output-format json)"
  CONFIG_DIGEST="$(printf '%s\n' "$CONFIG_JSON" | perl "$HELPER" read-digest)"
  [[ "$CONFIG_DIGEST" =~ ^[0-9a-fA-F]{40}$ ]] || die "Proxmox did not return a valid configuration digest."
fi
VM_CONFIG="$(qm config "$VMID")"
# An omitted bios option uses Proxmox's SeaBIOS default.
BIOS="$(printf '%s\n' "$VM_CONFIG" | awk '$1 == "bios:" {print $2}')"
case "$BIOS" in
  ""|seabios) FIRMWARE=bios ;;
  ovmf) FIRMWARE=uefi ;;
  *) echo "ERROR: Unsupported VM firmware: $BIOS" >&2; exit 1 ;;
esac
# Recognize only our own generated seed media when reusing a CD-ROM slot.
MANAGED_SLOT=""
while IFS= read -r LINE; do
  if [[ "$LINE" =~ ^(ide[0-3]|sata[0-5]|scsi[0-9]+): ]]; then
    DEVICE="${LINE%%:*}"
    DRIVE="${LINE#*: }"
    VOLUME="${DRIVE%%,*}"
    VOLUME="${VOLUME#file=}"
    if [[ "$VOLUME" =~ ^[A-Za-z][A-Za-z0-9._-]*:iso/autoinstall-seed-${VMID}-[0-9a-f]{32}\.iso$ ]]; then
      [[ ",$DRIVE," == *,media=cdrom,* ]] || die "Generated seed is attached as a disk at $DEVICE; inspect the VM configuration."
      [[ -z "$MANAGED_SLOT" ]] || die "Multiple generated seed drives are attached; keep only one."
      MANAGED_SLOT="$DEVICE"
    elif (( STATIC_MODE )) && [[ "$VOLUME" == *cloudinit* ]]; then
      die "An existing cloud-init drive at $DEVICE would compete with the local seed; detach it first."
    fi
  fi
done <<< "$VM_CONFIG"
if (( STATIC_MODE )); then
  if [[ -n "$MANAGED_SLOT" ]]; then
    [[ -z "$SEED_SLOT" || "$SEED_SLOT" == "$MANAGED_SLOT" ]] || die "Reuse the existing seed slot $MANAGED_SLOT, or detach it before selecting another slot."
    SEED_SLOT="$MANAGED_SLOT"
  else
    if [[ -z "$SEED_SLOT" ]]; then
      for CANDIDATE in ide3 ide1 ide0 ide2; do
        if ! printf '%s\n' "$VM_CONFIG" | grep "^$CANDIDATE:" > /dev/null; then
          SEED_SLOT="$CANDIDATE"
          break
        fi
      done
    fi
    [[ -n "$SEED_SLOT" ]] || die "No free IDE slot; select a free SATA slot with --seed-slot."
    if printf '%s\n' "$VM_CONFIG" | grep "^$SEED_SLOT:" > /dev/null; then
      die "Slot $SEED_SLOT is occupied; choose a free slot with --seed-slot."
    fi
  fi
elif [[ -n "$MANAGED_SLOT" ]]; then
  die "Detach the generated local seed CD-ROM at $MANAGED_SLOT before returning to web-seed mode."
fi
BASE="https://raw.githubusercontent.com/$REPO/$REF/profiles/$FIRMWARE/$PROFILE/"
SEED="ds=nocloud-net;s=$BASE"
if (( STATIC_MODE )); then
  # Remove any remote seed URL so cloud-init discovers CIDATA before networking.
  SEED=ds=nocloud
fi
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
      ""|ds=nocloud|ds=nocloud-net|ds=nocloud\;*|ds=nocloud-net\;*) continue ;;
      *) echo "ERROR: VM $VMID has an unrelated SMBIOS serial; merge manually to avoid losing it." >&2; exit 1 ;;
    esac
  fi
  if [[ "$ENCODED" != 1 ]]; then
    VALUE="$(printf %s "$VALUE" | base64 | tr -d '\n')"
  fi
  MERGED_SMBIOS+=",$KEY=$VALUE"
done
if (( STATIC_MODE )); then
  STORAGE_STATUS="$(pvesm status --storage "$STORAGE" --content iso --enabled 1)"
  if ! printf '%s\n' "$STORAGE_STATUS" | awk -v storage="$STORAGE" '$1 == storage && $3 == "active" { found=1 } END { exit !found }'; then
    die "Storage $STORAGE must be active and support ISO content."
  fi
  WORK_DIR="$(mktemp -d)"
  STAGED_ISO=""
  # Remove only temporary artifacts created by this invocation.
  cleanup() {
    [[ -z "$STAGED_ISO" ]] || rm -f -- "$STAGED_ISO"
    rm -rf -- "$WORK_DIR"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir "$WORK_DIR/input" "$WORK_DIR/seed"
  printf '%s\n' "$VM_CONFIG" > "$WORK_DIR/vm-config"
  for FILE in user-data meta-data; do
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 15 --max-time 120 --retry 2 \
      --output "$WORK_DIR/input/$FILE" "$BASE$FILE"
  done
  perl "$HELPER" render --ip "$IP" --gateway "$GATEWAY" --dns "$DNS" \
    --interface "$INTERFACE" --vmid "$VMID" --vm-config "$WORK_DIR/vm-config" \
    --input-dir "$WORK_DIR/input" --output-dir "$WORK_DIR/seed"
  RUN_ID="$(perl "$HELPER" new-id)"
  ISO_NAME="autoinstall-seed-$VMID-$RUN_ID.iso"
  ISO_VOLUME="$STORAGE:iso/$ISO_NAME"
  ISO_PATH="$(pvesm path "$ISO_VOLUME")"
  [[ "$ISO_PATH" == /* && "$ISO_PATH" != *$'\n'* && "${ISO_PATH##*/}" == "$ISO_NAME" ]] || die "Storage returned an unexpected ISO path."
  ISO_DIR="${ISO_PATH%/*}"
  [[ -d "$ISO_DIR" && -w "$ISO_DIR" ]] || die "ISO directory $ISO_DIR must exist and be writable."
  STAGED_ISO="$(mktemp "$ISO_DIR/.autoinstall-seed-$VMID.XXXXXX")"
  (
    cd "$WORK_DIR/seed"
    genisoimage -quiet -output "$STAGED_ISO" -volid cidata -joliet -rock \
      user-data meta-data network-config vendor-data
  )
  # Recheck before publishing the ISO; the digest also guards the final update.
  [[ "$(qm status "$VMID")" == "status: stopped" ]] || die "VM started while preparing the seed; no configuration was changed."
  [[ "$(qm config "$VMID")" == "$VM_CONFIG" ]] || die "VM configuration changed while preparing the seed; rerun the command."
  [[ ! -e "$ISO_PATH" ]] || die "Refusing to overwrite existing ISO $ISO_PATH."
  mv -- "$STAGED_ISO" "$ISO_PATH"
  STAGED_ISO=""
  if ! qm set "$VMID" --digest "$CONFIG_DIGEST" --smbios1 "$MERGED_SMBIOS" "--$SEED_SLOT" "$ISO_VOLUME,media=cdrom"; then
    die "Could not attach the seed; generated ISO retained at $ISO_PATH. Inspect the VM configuration before retrying."
  fi
  printf 'Attached local seed ISO: %s (%s)\n' "$ISO_VOLUME" "$SEED_SLOT"
  printf 'Static IPv4: %s, gateway: %s, DNS: %s, NIC: %s\n' "$IP" "$GATEWAY" "$DNS" "$INTERFACE"
  printf 'The installer reads its seed locally; identity is still configured interactively.\n'
else
  qm set "$VMID" --smbios1 "$MERGED_SMBIOS"
  printf 'Configured VM %s with NoCloud URL: %s\n' "$VMID" "$BASE"
  printf 'Cloud-init requires early network/DHCP to fetch profile before installer network screen.\n'
fi
printf 'Detected VM firmware: %s\n' "$FIRMWARE"
printf 'Start the VM from an Ubuntu Server live ISO. Installer may request disk-erasure confirmation.\n'
