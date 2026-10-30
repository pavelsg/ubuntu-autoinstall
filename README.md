# Proxmox Ubuntu Server 26.04 Autoinstall profiles

**Destructive:** all profiles wipe two virtual disks, smaller OS disk (32 GiB) and larger MySQL disk (48 GiB). Always validate on a disposable VM before production.

## Profiles

| Directory | Firmware | Installed IPv6 | Disk layout |
|---|---|---|---|
| `profiles/mysql-2disk-uefi/` | OVMF/UEFI | enabled/default | 32G OS + 48G MySQL |
| `profiles/mysql-2disk-uefi-noipv6/` | OVMF/UEFI | disabled | 32G OS + 48G MySQL |
| `profiles/mysql-2disk-bios/` | SeaBIOS/BIOS | enabled/default | 32G OS + 48G MySQL |
| `profiles/mysql-2disk-bios-noipv6/` | SeaBIOS/BIOS | disabled | 32G OS + 48G MySQL |

Each directory contains `user-data` (`#cloud-config`) and `meta-data` for the Cloud-init NoCloud web datasource. Do not rename them to `.yaml` on the public URL. A single `autoinstall.yaml` URL by itself is not a NoCloud seed directory.

All profiles use the `en_US.UTF-8` locale and US keyboard layout, select the Ubuntu Server minimal installation source, configure no proxy, and request no additional snaps. The minimal image may itself include snaps; the profiles do not remove them. The source ID depends on the ISO: confirm `ubuntu-server-minimal` appears in its `casper/install-sources.yaml` before installation. Network and identity remain interactive, and OpenSSH Server is selected for installation.

## Setup

1. Publish this directory tree in a **public GitHub repository**, preferably pinning a known Git commit/tag instead of referencing a moving branch (`main`) for production installations.
2. Prepare a fresh Proxmox VM with **only two target disks** of 32 GiB and 48 GiB, plus the Ubuntu Server ISO as a CD-ROM. Firmware `OVMF` for `*-uefi`, `SeaBIOS` for `*-bios`. Use a network offering DHCP during the initial live boot.
3. On the Proxmox host, set the cloud-init URL in the VM's SMBIOS serial (replace the sample repo with yours):

   ```bash
   ./set-proxmox-seed.sh 120 your-org/ubuntu-proxmox-autoinstall mysql-2disk-uefi-noipv6 main
   qm start 120
   ```

   This script **refuses** to replace an existing SMBIOS1 config. Alternatively, edit the ISO GRUB `linux` command line to include:

   ```text
   autoinstall ds=nocloud\;s=https://raw.githubusercontent.com/your-org/ubuntu-proxmox-autoinstall/main/profiles/mysql-2disk-uefi-noipv6/
   ```

   GRUB must escape the semicolon (`\;`). Use the profile's trailing `/` URL, not a link directly to `user-data`.

4. At the Ubuntu installer: provide **network settings** (`DHCP` or `Manual IPv4` with subnet, IP, gateway, DNS) and **identity** (hostname, username, password). Storage partitioning is not presented for editing. Disk wipe confirmation may still appear if `autoinstall` is not on the installer kernel command line.
5. After installation, remove or deprioritize the ISO and reboot. Verify `lsblk`, `sudo lvs`, `ip -4 addr`, `ip route`, `resolvectl status`, and for no-IPv6 variants `cat /proc/sys/net/ipv6/conf/all/disable_ipv6`.

## Important networking limitation

The web-hosted seed is fetched **before** the installer network configuration screen. It normally requires DHCP and access to GitHub **before** you can configure a permanent static address. If the VM network has no DHCP, use a local NoCloud seed ISO instead (see below), temporarily enable DHCP, or provide suitable early-boot networking.

For a local seed ISO (can be built on Linux):

```bash
sudo apt install cloud-image-utils
cd profiles/mysql-2disk-uefi-noipv6
cloud-localds seed.iso user-data meta-data
```

Attach `seed.iso` as an additional virtual CD drive in Proxmox (not a target disk). The seed profile will then be accessible without GitHub or DHCP. You still need network connectivity for updates/packages when the installation requires it.

## Disable IPv6

The `*-noipv6` profiles write `/etc/sysctl.d/99-disable-ipv6.conf` **in the installed system**, setting `net.ipv6.conf.all.disable_ipv6=1` and `net.ipv6.conf.default.disable_ipv6=1`. This takes effect after reboot. The live install environment can still use IPv6; this is intentional because the seed is fetched first. To disable only *automatic IPv6 addressing*, not the IPv6 stack, consider Netplan `dhcp6: false`, `accept-ra: false`, `link-local: []` in a noninteractive `network` definition instead.

## Static network as fully unattended alternative

Remove `network` from `interactive-sections`, and add a Netplan-style `autoinstall.network` section. For example (adapt interface name/MAC and addresses):

```yaml
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
      addresses: [192.0.2.10/24]
      routes:
        - to: default
          via: 192.0.2.1
      nameservers:
        addresses: [1.1.1.1, 9.9.9.9]
```

This sample shows the `network` contents nested under `autoinstall:`, and requires per-VM adaptation. It does *not* solve the early network connectivity needed to fetch a web profile, so local NoCloud ISO or separate early-boot networking may still be needed.

## Add more profiles

Copy an existing profile directory, change only `storage.config` and choose an appropriate boot layout. For reusable templates with same-size disks, don't use `size: smallest` / `largest`: set Proxmox virtual-disk serials and match by `serial:` instead. Use a separate folder for each profile, with both `user-data` and `meta-data` present.

* For UEFI, create a FAT32 EFI System Partition at `/boot/efi` (example uses 1 GiB).
* For BIOS with GPT, create a 1 MiB `bios_grub` partition.
* `lv_tmp` uses the rest of the MySQL VG due to LVM metadata overhead, approximately 4 GiB rather than precisely 4 GiB.
* MySQL requires separate application configuration to use these directories; mounts alone do not configure MySQL.

## Validation

Run the profile setting and YAML syntax checks with Ruby (standard library only):

```bash
ruby tests/profile_settings_test.rb
```

The profiles have **not** been installed in a real VM. Validate with the [official Subiquity validation script](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/autoinstall-validation.html) and then test in a disposable Proxmox VM.

References:
- https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html
- https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html
- https://curtin.readthedocs.io/en/latest/topics/storage.html
- https://pve.proxmox.com/pve-docs/qm.1.html

**Security:** Never commit login passwords, password hashes you actually use, API credentials, or private SSH keys into this public repository. The interactive identity screen intentionally prompts for credentials at install time.
