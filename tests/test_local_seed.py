"""Validate generated static networking and local NoCloud seed contents."""

from copy import deepcopy
from ipaddress import IPv4Address, IPv4Interface
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

# The helper is a stable module at the repository root, not a plugin import.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_local_seed import (  # noqa: E402
    NetworkSettings,
    build_network,
    interface_mac,
    parse_network,
    render_seed,
)


REPOSITORY = Path(__file__).resolve().parents[1]
HELPER = REPOSITORY / "prepare_local_seed.py"
VM_CONFIG = "bios: ovmf\nnet0: virtio=BC:24:11:12:34:56,bridge=vmbr0,firewall=1\n"


class NetworkSettingsTest(unittest.TestCase):
    """Exercise network validation at reusable helper boundaries."""

    def test_dns_defaults_to_gateway_and_explicit_dns_is_preserved(self) -> None:
        """Use the gateway for DNS only when the option is omitted."""
        defaults = parse_network("10.0.0.34/24", "10.0.0.1")
        explicit = parse_network("10.0.0.34/24", "10.0.0.1", "9.9.9.9")
        self.assertEqual(IPv4Address("10.0.0.1"), defaults.dns)
        self.assertEqual(IPv4Address("9.9.9.9"), explicit.dns)
        self.assertEqual("10.0.0.34/24", str(defaults.address))

    def test_invalid_network_values_are_rejected(self) -> None:
        """Reject malformed addresses and routes that cannot reach a gateway."""
        invalid = [
            ("10.0.0.34", "10.0.0.1", None),
            ("10.0.0.34/255.255.255.0", "10.0.0.1", None),
            ("10.0.0.34/33", "10.0.0.1", None),
            ("10.0.0.999/24", "10.0.0.1", None),
            ("10.0.0.0/24", "10.0.0.1", None),
            ("10.0.0.255/24", "10.0.0.1", None),
            ("10.0.0.34/24", "10.0.1.1", None),
            ("10.0.0.34/24", "10.0.0.0", None),
            ("10.0.0.34/24", "10.0.0.255", None),
            ("10.0.0.34/24", "10.0.0.34", None),
            ("10.0.0.34/24", "10.0.0.1", ""),
            ("10.0.0.34/24", "10.0.0.1", "dns.example.com"),
            ("10.0.0.34/24", "10.0.0.1", "224.0.0.1"),
            ("127.0.0.1/8", "127.0.0.2", None),
            ("0.0.0.1/24", "0.0.0.2", None),
            ("224.0.0.2/24", "224.0.0.1", None),
            ("240.0.0.2/24", "240.0.0.1", None),
            ("::1/128", "::2", None),
            ("10.0.0.34/24", "::1", None),
        ]
        for ip, gateway, dns in invalid:
            with self.subTest(ip=ip, gateway=gateway, dns=dns):
                with self.assertRaises(ValueError):
                    parse_network(ip, gateway, dns)

    def test_31_peers_and_32_on_link_route(self) -> None:
        """Handle point-to-point subnets and routed single-host addresses."""
        point_to_point = parse_network("10.0.0.0/31", "10.0.0.1")
        single_host = parse_network("10.0.0.34/32", "10.0.0.1")
        normal = build_network(point_to_point, "BC:24:11:12:34:56")
        routed = build_network(single_host, "BC:24:11:12:34:56")
        self.assertNotIn("on-link", normal["ethernets"]["install_nic"]["routes"][0])
        self.assertTrue(routed["ethernets"]["install_nic"]["routes"][0]["on-link"])

    def test_model_and_builder_validate_runtime_inputs(self) -> None:
        """Do not rely on type annotations for external helper inputs."""
        with self.assertRaises(ValueError):
            NetworkSettings("10.0.0.34/24", IPv4Address("10.0.0.1"), IPv4Address("10.0.0.1"))
        with self.assertRaises(ValueError):
            NetworkSettings(IPv4Interface("10.0.0.34/24"), "10.0.0.1", IPv4Address("10.0.0.1"))
        with self.assertRaises(ValueError):
            build_network({}, "BC:24:11:12:34:56")
        with self.assertRaises(ValueError):
            build_network(parse_network("10.0.0.34/24", "10.0.0.1"), "ff:ff:ff:ff:ff:ff")
        with self.assertRaises(ValueError):
            build_network(parse_network("10.0.0.34/24", "10.0.0.1"), "not-a-mac")
        with self.assertRaises(ValueError):
            interface_mac(None, "net0")
        with self.assertRaises(ValueError):
            interface_mac(VM_CONFIG, None)

    def test_selects_nic_by_proxmox_key_and_matches_mac(self) -> None:
        """Select the requested adapter regardless of its guest-side name."""
        config = VM_CONFIG + "net1: e1000=02:12:34:56:78:9A,bridge=vmbr1\n"
        self.assertEqual("bc:24:11:12:34:56", interface_mac(config, "net0"))
        self.assertEqual("02:12:34:56:78:9a", interface_mac(config, "net1"))
        network = build_network(parse_network("10.0.0.34/24", "10.0.0.1"), interface_mac(config, "net1"))
        nic = network["ethernets"]["install_nic"]
        self.assertEqual({"macaddress": "02:12:34:56:78:9a"}, nic["match"])
        self.assertFalse(nic["dhcp4"])
        self.assertNotIn("dhcp6", nic)
        self.assertNotIn("accept-ra", nic)
        self.assertNotIn("set-name", nic)

    def test_missing_disabled_or_malformed_adapter_is_rejected(self) -> None:
        """Avoid applying an IP to an ambiguous or unavailable NIC."""
        invalid = [
            (VM_CONFIG, "net1"),
            (VM_CONFIG, "ens18"),
            (VM_CONFIG + VM_CONFIG, "net0"),
            ("net0: virtio=BC:24:11:12:34:56,link_down=1", "net0"),
            ("net0: virtio=BC:24:11:12:34:56,link_down=on", "net0"),
            ("net0: virtio=invalid", "net0"),
            ("net0: virtio=00:00:00:00:00:00", "net0"),
            ("net0: virtio=01:00:00:00:00:01", "net0"),
            ("net0: virtio=BC:24:11:12:34:56,virtio=02:12:34:56:78:9a", "net0"),
            ("net0: virtio=BC:24:11:12:34:56,e1000=02:12:34:56:78:9a", "net0"),
            ("net0: bridge=vmbr0", "net0"),
            ("net0: virtio=BC:24:11:12:34:56,malformed", "net0"),
        ]
        for config, interface in invalid:
            with self.subTest(config=config, interface=interface):
                with self.assertRaises(ValueError):
                    interface_mac(config, interface)


class SeedRenderingTest(unittest.TestCase):
    """Check transformed seed data using all repository profile variants."""

    def test_every_profile_preserves_storage_identity_and_ipv6_settings(self) -> None:
        """Only change network, interactive network selection, and instance ID."""
        settings = parse_network("10.0.0.34/24", "10.0.0.1")
        paths = sorted((REPOSITORY / "profiles").glob("*/*/user-data"))
        self.assertEqual(8, len(paths))
        instance_ids = []
        with tempfile.TemporaryDirectory() as temporary:
            for index, path in enumerate(paths):
                with self.subTest(profile=str(path.parent)):
                    output = Path(temporary) / str(index)
                    original = yaml.safe_load(path.read_text())
                    metadata = yaml.safe_load((path.parent / "meta-data").read_text())
                    render_seed(path.parent, output, 103, VM_CONFIG, "net0", settings)
                    actual = yaml.safe_load((output / "user-data").read_text())
                    network = yaml.safe_load((output / "network-config").read_text())
                    expected = deepcopy(original)
                    expected["autoinstall"]["network"] = network
                    expected["autoinstall"]["interactive-sections"] = ["identity"]
                    self.assertEqual(expected, actual)
                    self.assertTrue((output / "user-data").read_text().startswith("#cloud-config\n"))
                    self.assertEqual(["10.0.0.1"], network["ethernets"]["install_nic"]["nameservers"]["addresses"])
                    actual_metadata = yaml.safe_load((output / "meta-data").read_text())
                    self.assertNotEqual(metadata["instance-id"], actual_metadata["instance-id"])
                    self.assertTrue(actual_metadata["instance-id"].startswith("iid-autoinstall-103-"))
                    instance_ids.append(actual_metadata["instance-id"])
                    self.assertEqual({}, yaml.safe_load((output / "vendor-data").read_text()))
                    self.assertEqual(original, yaml.safe_load(path.read_text()))
        self.assertEqual(len(instance_ids), len(set(instance_ids)))

    def test_invalid_profile_documents_do_not_create_output(self) -> None:
        """Reject malformed or executable YAML before creating seed files."""
        invalid = [
            "autoinstall:\n  version: 1\n  storage: {}\n",
            "#cloud-config\n- not-a-mapping\n",
            "#cloud-config\nautoinstall: false\n",
            "#cloud-config\nautoinstall: {version: true, storage: {}}\n",
            "#cloud-config\nautoinstall: {version: 2, storage: {}}\n",
            "#cloud-config\nautoinstall: {version: 1}\n",
            "#cloud-config\nautoinstall: {version: 1, storage: {}, interactive-sections: network}\n",
            "#cloud-config\nautoinstall: {version: 1, storage: {}, interactive-sections: ['*']}\n",
            "#cloud-config\nautoinstall: [\n",
            "#cloud-config\n!!python/object/apply:os.system ['false']\n",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = root / "input"
            inputs.mkdir()
            (inputs / "meta-data").write_text("instance-id: test\n")
            for index, content in enumerate(invalid):
                with self.subTest(content=content):
                    (inputs / "user-data").write_text(content)
                    output = root / str(index)
                    with self.assertRaises(ValueError):
                        render_seed(inputs, output, 103, VM_CONFIG, "net0", parse_network("10.0.0.34/24", "10.0.0.1"))
                    self.assertFalse(output.exists())

    def test_bad_metadata_vmid_and_occupied_output_are_rejected(self) -> None:
        """Protect existing files and reject invalid rendering arguments."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = root / "input"
            inputs.mkdir()
            (inputs / "user-data").write_text("#cloud-config\nautoinstall: {version: 1, storage: {}}\n")
            (inputs / "meta-data").write_text("[]\n")
            settings = parse_network("10.0.0.34/24", "10.0.0.1")
            with self.assertRaises(ValueError):
                render_seed(inputs, root / "output", 103, VM_CONFIG, "net0", settings)
            (inputs / "meta-data").write_text("{}\n")
            for vmid in (0, -1, True, "103"):
                with self.subTest(vmid=vmid), self.assertRaises(ValueError):
                    render_seed(inputs, root / "output", vmid, VM_CONFIG, "net0", settings)
            with self.assertRaises(ValueError):
                render_seed(inputs, inputs, 103, VM_CONFIG, "net0", settings)
            output = root / "output"
            output.mkdir()
            sentinel = output / "sentinel"
            sentinel.write_text("keep")
            with self.assertRaises(ValueError):
                render_seed(inputs, output, 103, VM_CONFIG, "net0", settings)
            self.assertEqual("keep", sentinel.read_text())

    def test_render_cli_uses_selected_interface_and_dns_override(self) -> None:
        """Exercise real command-line parsing and output generation."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "vm-config"
            config.write_text(VM_CONFIG + "net1: virtio=02:12:34:56:78:9A,bridge=vmbr1\n")
            output = root / "seed"
            result = subprocess.run([
                sys.executable, str(HELPER), "render", "--ip", "10.0.0.34/24",
                "--gateway", "10.0.0.1", "--dns", "9.9.9.9", "--vm-config", str(config),
                "--interface", "net1", "--vmid", "103", "--input-dir",
                str(REPOSITORY / "profiles/uefi/single-disk-noipv6"), "--output-dir", str(output),
            ], capture_output=True, text=True, check=False)
            self.assertEqual(0, result.returncode, result.stderr)
            network = yaml.safe_load((output / "network-config").read_text())
            nic = network["ethernets"]["install_nic"]
            self.assertEqual(["9.9.9.9"], nic["nameservers"]["addresses"])
            self.assertEqual("02:12:34:56:78:9a", nic["match"]["macaddress"])

    def test_validate_cli_returns_clear_errors(self) -> None:
        """Provide actionable validation failures without tracebacks."""
        for ip, expected in (("10.0.0.34/24", 0), ("10.0.0.34", 1)):
            result = subprocess.run([
                sys.executable, str(HELPER), "validate-network", "--ip", ip, "--gateway", "10.0.0.1",
            ], capture_output=True, text=True, check=False)
            self.assertEqual(expected, result.returncode)
            self.assertEqual("", result.stdout)
            if expected:
                self.assertIn("ERROR:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_render_cli_reports_missing_file_without_traceback(self) -> None:
        """Report file access failures as concise command-line errors."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = subprocess.run([
                sys.executable, str(HELPER), "render", "--ip", "10.0.0.34/24",
                "--gateway", "10.0.0.1", "--vm-config", str(root / "missing-config"),
                "--vmid", "103", "--input-dir", str(root / "missing-input"),
                "--output-dir", str(root / "output"),
            ], capture_output=True, text=True, check=False)
            self.assertEqual(1, result.returncode)
            self.assertEqual("", result.stdout)
            self.assertIn("ERROR:", result.stderr)
            self.assertIn("missing-config", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertFalse((root / "output").exists())


if __name__ == "__main__":
    unittest.main()
