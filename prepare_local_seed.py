#!/usr/bin/env python3
"""Validate static IPv4 settings and render per-VM NoCloud seed files."""

from __future__ import annotations

import argparse
from copy import deepcopy
from dataclasses import dataclass
from ipaddress import IPv4Address, IPv4Interface, IPv4Network
from pathlib import Path
import re
import sys
from typing import Any
from uuid import uuid4

import yaml


@dataclass(frozen=True)
class NetworkSettings:
    """Validated static IPv4 settings for one installation interface.

    Attributes:
        address: Host address with its network prefix.
        gateway: Default route's next hop.
        dns: DNS server, defaulting to the gateway at the parsing boundary.
    """

    address: IPv4Interface
    gateway: IPv4Address
    dns: IPv4Address

    def __post_init__(self) -> None:
        """Reject invalid settings even when constructed outside the CLI.

        Raises:
            ValueError: A value is not an IPv4 address or is unusable.
        """
        if not isinstance(self.address, IPv4Interface):
            raise ValueError("IP must be an IPv4 host address with a CIDR prefix")
        validate_unicast(self.address.ip, "IP")
        validate_unicast(self.gateway, "Gateway")
        validate_unicast(self.dns, "DNS")
        network = self.address.network
        if network.prefixlen <= 30 and self.address.ip in (
            network.network_address, network.broadcast_address
        ):
            raise ValueError("IP must be a host address, not the subnet or broadcast address")
        if self.gateway == self.address.ip:
            raise ValueError("Gateway must differ from the host IP")
        # /32 routes explicitly mark the gateway on-link; /31 has two usable hosts.
        if network.prefixlen != 32 and self.gateway not in network:
            raise ValueError("Gateway must be within the IP subnet (except for /32)")
        if network.prefixlen <= 30 and self.gateway in (
            network.network_address, network.broadcast_address
        ):
            raise ValueError("Gateway must be a host address, not the subnet or broadcast address")


def validate_unicast(address: IPv4Address, label: str) -> None:
    """Validate that an address can identify a unicast network endpoint.

    Args:
        address: Parsed IPv4 address to validate.
        label: Name used in a validation error.

    Raises:
        ValueError: The address is not a usable unicast IPv4 address.
    """
    if type(address) is not IPv4Address or (
        address.is_unspecified or address.is_multicast or address.is_loopback
        or address.is_reserved or address in IPv4Network("0.0.0.0/8")
    ):
        raise ValueError(f"{label} must be a usable unicast IPv4 address")


def parse_network(ip: str, gateway: str, dns: str | None = None) -> NetworkSettings:
    """Parse CLI strings into validated static IPv4 settings.

    Args:
        ip: IPv4 host address with an explicit numeric CIDR prefix.
        gateway: IPv4 gateway address.
        dns: Optional IPv4 DNS server; omission selects the gateway.

    Returns:
        Validated settings ready for Netplan rendering.

    Raises:
        ValueError: A string or its network relationship is invalid.
    """
    if not isinstance(ip, str) or not re.fullmatch(r"[0-9.]+/[0-9]{1,2}", ip):
        raise ValueError("IP must include a numeric CIDR prefix, for example 10.0.0.34/24")
    if not isinstance(gateway, str) or (dns is not None and not isinstance(dns, str)):
        raise ValueError("Gateway and DNS must be IPv4 address strings")
    try:
        address = IPv4Interface(ip)
        gateway_address = IPv4Address(gateway)
        dns_address = IPv4Address(gateway if dns is None else dns)
    except ValueError as error:
        raise ValueError(f"Invalid IPv4 configuration: {error}") from error
    return NetworkSettings(address, gateway_address, dns_address)


def interface_mac(vm_config: str, interface: str) -> str:
    """Read the selected Proxmox network adapter's MAC address.

    Args:
        vm_config: Text returned by ``qm config``.
        interface: Proxmox adapter key, for example ``net0``.

    Returns:
        Lowercase unicast MAC address used to match the guest interface.

    Raises:
        ValueError: The adapter is missing, ambiguous, disabled, or malformed.
    """
    if not isinstance(vm_config, str) or not isinstance(interface, str):
        raise ValueError("VM configuration and interface must be strings")
    if not re.fullmatch(r"net[0-9]+", interface):
        raise ValueError("Interface must be a Proxmox network key such as net0")
    lines = [line.split(":", 1)[1].strip() for line in vm_config.splitlines()
             if line.startswith(f"{interface}:")]
    if len(lines) != 1:
        raise ValueError(f"Expected one configured {interface} adapter")
    fields: dict[str, str] = {}
    for field in lines[0].split(","):
        key, separator, value = field.partition("=")
        if not separator or key in fields:
            raise ValueError(f"Malformed {interface} adapter configuration")
        fields[key] = value
    if fields.get("link_down", "0").lower() not in ("0", "off", "false", "no"):
        raise ValueError(f"Adapter {interface} has its link disabled")
    models = {
        "e1000", "e1000-82540em", "e1000-82544gc", "e1000-82545em", "e1000e",
        "i82551", "i82557b", "i82559er", "ne2k_isa", "ne2k_pci", "pcnet",
        "rtl8139", "virtio", "vmxnet3",
    }
    macs = [value for key, value in fields.items() if key in models]
    if len(macs) != 1 or not re.fullmatch(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", macs[0]):
        raise ValueError(f"Adapter {interface} needs one explicit MAC address")
    mac = macs[0].lower()
    if int(mac[:2], 16) & 1 or mac == "00:00:00:00:00:00":
        raise ValueError(f"Adapter {interface} needs a nonzero unicast MAC address")
    return mac


def build_network(settings: NetworkSettings, mac: str) -> dict[str, Any]:
    """Create matching cloud-init and installer Netplan configuration.

    Args:
        settings: Validated IPv4 settings.
        mac: Unicast MAC address from the selected Proxmox adapter.

    Returns:
        A version 2 network configuration matching the adapter by MAC.

    Raises:
        ValueError: The settings or MAC are invalid.
    """
    if not isinstance(settings, NetworkSettings):
        raise ValueError("Settings must be validated NetworkSettings")
    # Use the same MAC validation at both externally callable boundaries.
    normalized_mac = interface_mac(f"net0: virtio={mac}", "net0")
    route: dict[str, Any] = {"to": "default", "via": str(settings.gateway)}
    if settings.address.network.prefixlen == 32:
        route["on-link"] = True
    return {
        "version": 2,
        "ethernets": {
            "install_nic": {
                "match": {"macaddress": normalized_mac},
                "dhcp4": False,
                "addresses": [str(settings.address)],
                "routes": [route],
                "nameservers": {"addresses": [str(settings.dns)]},
            }
        },
    }


def load_mapping(path: Path) -> dict[str, Any]:
    """Load a YAML mapping without executing YAML object constructors.

    Args:
        path: UTF-8 YAML file to read.

    Returns:
        The file's mapping.

    Raises:
        ValueError: The document is invalid YAML or has a non-mapping root.
        OSError: The file cannot be read.
    """
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as error:
        raise ValueError(f"Invalid YAML in {path.name}: {error}") from error
    if not isinstance(document, dict) or not all(isinstance(key, str) for key in document):
        raise ValueError(f"{path.name} must contain a mapping with string keys")
    return document


def render_seed(input_dir: Path, output_dir: Path, vmid: int, vm_config: str,
                interface: str, settings: NetworkSettings) -> None:
    """Render local NoCloud files while preserving unrelated profile settings.

    Args:
        input_dir: Directory containing downloaded user-data and meta-data.
        output_dir: Empty directory for the generated seed files.
        vmid: Positive Proxmox VM identifier.
        vm_config: Text returned by ``qm config``.
        interface: Adapter key whose MAC identifies the guest interface.
        settings: Validated static IPv4 settings.

    Raises:
        ValueError: Input files, network settings, or output destination are invalid.
        OSError: Files cannot be read or written.
    """
    if isinstance(vmid, bool) or not isinstance(vmid, int) or vmid <= 0:
        raise ValueError("VMID must be a positive integer")
    if not isinstance(input_dir, Path) or not isinstance(output_dir, Path):
        raise ValueError("Input and output directories must be pathlib Paths")
    if input_dir.resolve() == output_dir.resolve():
        raise ValueError("Input and output directories must differ")
    if output_dir.exists() and (not output_dir.is_dir() or any(output_dir.iterdir())):
        raise ValueError("Output directory must be empty")
    user_path = input_dir / "user-data"
    if not user_path.read_text(encoding="utf-8").startswith("#cloud-config\n"):
        raise ValueError("user-data must begin with a #cloud-config header")
    user_data = load_mapping(user_path)
    metadata = load_mapping(input_dir / "meta-data")
    autoinstall = user_data.get("autoinstall")
    if not isinstance(autoinstall, dict) or type(autoinstall.get("version")) is not int or autoinstall["version"] != 1:
        raise ValueError("user-data must contain autoinstall version 1")
    if not isinstance(autoinstall.get("storage"), dict):
        raise ValueError("autoinstall must contain a storage mapping")
    sections = autoinstall.get("interactive-sections", [])
    if not isinstance(sections, list) or not all(isinstance(section, str) for section in sections):
        raise ValueError("interactive-sections must be a list of strings")
    if "*" in sections:
        raise ValueError("Wildcard interactive-sections cannot be combined with static networking")
    network = build_network(settings, interface_mac(vm_config, interface))
    autoinstall["network"] = deepcopy(network)
    autoinstall["interactive-sections"] = [section for section in sections if section != "network"]
    metadata["instance-id"] = f"iid-autoinstall-{vmid}-{uuid4().hex}"
    output_dir.mkdir(parents=True, exist_ok=True)
    documents = {
        "user-data": "#cloud-config\n" + yaml.safe_dump(user_data, sort_keys=False),
        "meta-data": yaml.safe_dump(metadata, sort_keys=False),
        "network-config": yaml.safe_dump(network, sort_keys=False),
        "vendor-data": "#cloud-config\n{}\n",
    }
    for name, content in documents.items():
        (output_dir / name).write_text(content, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    """Run the validation or rendering command.

    Args:
        argv: Command-line arguments, defaulting to the process arguments.

    Returns:
        Zero on success or one for invalid configuration and file errors.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("validate-network", "render"):
        command = commands.add_parser(name)
        command.add_argument("--ip", required=True)
        command.add_argument("--gateway", required=True)
        command.add_argument("--dns")
        if name == "render":
            command.add_argument("--vm-config", required=True, type=Path)
            command.add_argument("--interface", default="net0")
            command.add_argument("--vmid", required=True, type=int)
            command.add_argument("--input-dir", required=True, type=Path)
            command.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        settings = parse_network(args.ip, args.gateway, args.dns)
        if args.command == "render":
            render_seed(args.input_dir, args.output_dir, args.vmid,
                        args.vm_config.read_text(encoding="utf-8"), args.interface, settings)
    except (ValueError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
