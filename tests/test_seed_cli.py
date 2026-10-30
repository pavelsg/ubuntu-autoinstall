"""Exercise local seed orchestration against mocked host commands."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "set-proxmox-seed.sh"
UUID = "10e77876-6ab6-48dc-888b-05df0d1f7d62"
MAC = "BC:24:11:12:34:56"
BASE_CONFIG = (
    f"smbios1: uuid={UUID}\n"
    f"net0: virtio={MAC},bridge=vmbr0\n"
    "ide2: local:iso/ubuntu-server.iso,media=cdrom\n"
    "scsi0: local-lvm:vm-103-disk-0,size=32G"
)

# All host-facing commands share a fixture-backed adapter. It never accesses a VM
# or the network, but executes the real renderer with the real profile files.
MOCK_COMMAND = r'''
import json
import os
from pathlib import Path
import shutil
import sys

state_path = Path(os.environ["SEED_TEST_STATE"])
state = json.loads(state_path.read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with Path(state["log"]).open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if state.get("fail") == name or state.get("fail") == name + " " + args[0]:
    sys.exit(1)
if name == "qm":
    if args[0] == "status":
        print("status: " + state.get("status", "stopped"))
    elif args[0] == "config":
        count = state.get("config_reads", 0) + 1
        state["config_reads"] = count
        state_path.write_text(json.dumps(state))
        print(state["config"])
        if count > 1 and state.get("change_config"):
            print("name: changed-during-download")
    elif args[0] != "set":
        sys.exit(2)
elif name == "pvesm":
    if args[0] == "status":
        storage = args[args.index("--storage") + 1]
        print("Name Type Status Total Used Available %")
        print(storage + " dir " + state.get("storage_status", "active") + " 100 0 100 0")
    elif args[0] == "path":
        print(str(Path(state["storage_dir"]) / args[1].split("/", 1)[1]))
    else:
        sys.exit(2)
elif name == "pvesh":
    print(json.dumps({"digest": state.get("digest", "f" * 40)}))
elif name == "curl":
    output = Path(args[args.index("--output") + 1])
    if state.get("bad_yaml"):
        output.write_text("<html>not a profile</html>")
    else:
        relative = args[-1].split("/profiles/", 1)[1]
        shutil.copyfile(Path(state["repo"]) / "profiles" / relative, output)
elif name == "genisoimage":
    contents = {name: Path(name).read_text() for name in args[-4:]}
    Path(state["capture"]).write_text(json.dumps(contents))
    Path(args[args.index("-output") + 1]).write_bytes(b"mock ISO artifact")
else:
    sys.exit(2)
'''


class LocalSeedCliTest(unittest.TestCase):
    """Verify the full CLI without changing real VM configuration."""

    def setUp(self) -> None:
        """Create isolated command adapters and storage for each invocation."""
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.bin_dir = self.directory / "bin"
        self.bin_dir.mkdir()
        self.storage_dir = self.directory / "storage"
        self.storage_dir.mkdir()
        self.state_path = self.directory / "state.json"
        self.state = {
            "log": str(self.directory / "commands.jsonl"),
            "capture": str(self.directory / "seed.json"),
            "storage_dir": str(self.storage_dir),
            "repo": str(ROOT),
            "config": BASE_CONFIG,
        }
        self.save_state()
        for command in ("qm", "pvesm", "pvesh", "curl", "genisoimage"):
            path = self.bin_dir / command
            path.write_text(f"#!{sys.executable}\n" + MOCK_COMMAND)
            path.chmod(0o755)
        python = self.bin_dir / "python3"
        python.write_text(f'#!/bin/sh\nexec {shlex.quote(sys.executable)} "$@"\n')
        python.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": str(self.bin_dir) + os.pathsep + os.environ["PATH"],
            "SEED_TEST_STATE": str(self.state_path),
        }

    def save_state(self) -> None:
        """Write the command adapters' configured behavior."""
        self.state_path.write_text(json.dumps(self.state))

    def run_cli(self, *options: str, static: bool = True) -> subprocess.CompletedProcess[str]:
        """Run the real CLI with default or overridden static mode arguments.

        Args:
            options: Extra CLI arguments following the repository/profile selection.
            static: Whether to include the standard test address and gateway.

        Returns:
            Completed process with captured text output.
        """
        arguments = ["bash", str(SCRIPT), "103", "pavelsg/ubuntu-autoinstall", "single-disk-noipv6", "main"]
        if static:
            arguments.extend(["--ip", "10.0.0.34/24", "--gateway", "10.0.0.1"])
        return subprocess.run(arguments + list(options), env=self.env, text=True, capture_output=True, check=False)

    def commands(self) -> list[list[str]]:
        """Return commands observed by the mocked host adapters."""
        log = Path(self.state["log"])
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def assert_no_vm_update(self) -> None:
        """Require that validation or preparation failures never call qm set."""
        self.assertFalse(any(command[:2] == ["qm", "set"] for command in self.commands()))

    def test_static_seed_defaults_dns_to_gateway_and_keeps_existing_media(self) -> None:
        """Generate correct seed files and attach only the free CD-ROM slot."""
        result = self.run_cli()
        self.assertEqual(0, result.returncode, result.stderr)
        files = json.loads(Path(self.state["capture"]).read_text())
        config = yaml.safe_load(files["user-data"])["autoinstall"]
        network = yaml.safe_load(files["network-config"])
        self.assertEqual(config["network"], network)
        nic = network["ethernets"]["install_nic"]
        self.assertEqual(["10.0.0.34/24"], nic["addresses"])
        self.assertEqual(["10.0.0.1"], nic["nameservers"]["addresses"])
        self.assertEqual(MAC.lower(), nic["match"]["macaddress"])
        self.assertFalse(nic["dhcp4"])
        self.assertEqual(["identity"], config["interactive-sections"])
        self.assertIn("late-commands", config)
        updates = [command for command in self.commands() if command[:2] == ["qm", "set"]]
        self.assertEqual(1, len(updates))
        update = updates[0]
        self.assertIn("--ide3", update)
        self.assertNotIn("--ide2", update)
        self.assertNotIn("--scsi0", update)
        self.assertEqual("f" * 40, update[update.index("--digest") + 1])
        self.assertIn(f"uuid={UUID}", update[update.index("--smbios1") + 1])
        self.assertIn("serial=ZHM9bm9jbG91ZA==", update[update.index("--smbios1") + 1])
        self.assertIn("local:iso/autoinstall-seed-103-", update[-1])
        iso_command = next(command for command in self.commands() if command[0] == "genisoimage")
        self.assertEqual("cidata", iso_command[iso_command.index("-volid") + 1])
        self.assertEqual(["user-data", "meta-data", "network-config", "vendor-data"], iso_command[-4:])
        self.assertEqual(1, len(list(self.storage_dir.glob("*.iso"))))
        self.assertEqual([], list(self.storage_dir.glob(".*")))

    def test_overrides_use_uefi_selected_nic_dns_storage_and_slot(self) -> None:
        """Honor the explicitly selected adapter and storage without losing firmware detection."""
        self.state["config"] += "\nbios: ovmf\nnet1: e1000=02:00:00:00:00:02,bridge=vmbr1"
        self.save_state()
        result = self.run_cli("--dns", "1.1.1.1", "--interface", "net1", "--storage", "isos", "--seed-slot", "sata5")
        self.assertEqual(0, result.returncode, result.stderr)
        files = json.loads(Path(self.state["capture"]).read_text())
        config = yaml.safe_load(files["user-data"])["autoinstall"]
        nic = config["network"]["ethernets"]["install_nic"]
        self.assertEqual(["1.1.1.1"], nic["nameservers"]["addresses"])
        self.assertEqual("02:00:00:00:00:02", nic["match"]["macaddress"])
        self.assertTrue(any(action.get("path") == "/boot/efi" for action in config["storage"]["config"]))
        update = next(command for command in self.commands() if command[:2] == ["qm", "set"])
        self.assertIn("--sata5", update)
        self.assertTrue(update[-1].startswith("isos:iso/"))

    def test_existing_seed_slot_is_reused_and_previous_iso_is_preserved(self) -> None:
        """Rebuild the managed local seed without attaching competing CIDATA media."""
        old_name = "autoinstall-seed-103-" + "a" * 32 + ".iso"
        old_iso = self.storage_dir / old_name
        old_iso.write_bytes(b"previous seed")
        self.state["config"] += f"\nide1: local:iso/{old_name},media=cdrom"
        self.state["config"] = self.state["config"].replace(f"uuid={UUID}", f"uuid={UUID},base64=1,serial=ZHM9bm9jbG91ZA==")
        self.save_state()
        result = self.run_cli()
        self.assertEqual(0, result.returncode, result.stderr)
        update = next(command for command in self.commands() if command[:2] == ["qm", "set"])
        self.assertIn("--ide1", update)
        self.assertNotIn("--ide3", update)
        self.assertEqual(b"previous seed", old_iso.read_bytes())
        self.assertEqual(2, len(list(self.storage_dir.glob("*.iso"))))

    def test_automatic_slot_selection_skips_existing_devices(self) -> None:
        """Choose the next free slot when the preferred slot already holds media."""
        self.state["config"] += "\nide3: local:iso/tools.iso,media=cdrom"
        self.save_state()
        result = self.run_cli()
        self.assertEqual(0, result.returncode, result.stderr)
        update = next(command for command in self.commands() if command[:2] == ["qm", "set"])
        self.assertIn("--ide1", update)
        self.assertNotIn("--ide3", update)

    def test_invalid_options_stop_before_proxmox_commands(self) -> None:
        """Reject incomplete or malformed networking before any host interaction."""
        examples = [
            ["--ip", "10.0.0.34/24"],
            ["--gateway", "10.0.0.1"],
            ["--ip", "10.0.0.34", "--gateway", "10.0.0.1"],
            ["--ip", "10.0.0.999/24", "--gateway", "10.0.0.1"],
            ["--ip", "10.0.0.34/24", "--gateway", "10.0.0.1", "--dns", "invalid"],
            ["--ip", "10.0.0.34/24", "--gateway", "10.0.0.1", "--ip", "10.0.0.35/24"],
            ["--ip"], ["--ip", "--gateway"], ["--unknown", "value"],
        ]
        for options in examples:
            with self.subTest(options=options):
                result = self.run_cli(*options, static=False)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], self.commands())

    def test_preparation_failures_never_modify_vm_or_leave_partial_iso(self) -> None:
        """Exercise download, validation, storage, media and concurrent-edit failure paths."""
        examples = [
            {"fail": "curl"}, {"bad_yaml": True}, {"fail": "genisoimage"},
            {"storage_status": "inactive"}, {"status": "running"}, {"digest": "invalid"},
            {"config": BASE_CONFIG + "\nide3: local-lvm:vm-103-disk-1,size=10G", "options": ["--seed-slot", "ide3"]},
            {"config": BASE_CONFIG + "\nide0: disk0\nide1: disk1\nide3: disk3"},
            {"config": BASE_CONFIG.replace("net0:", "net1:")},
            {"config": BASE_CONFIG + "\nide0: local-lvm:vm-103-cloudinit,media=cdrom"},
            {"change_config": True},
        ]
        for behavior in examples:
            with self.subTest(behavior=behavior):
                self.state.update({"config": BASE_CONFIG, "config_reads": 0})
                self.state.update({key: value for key, value in behavior.items() if key != "options"})
                self.save_state()
                Path(self.state["log"]).unlink(missing_ok=True)
                result = self.run_cli(*behavior.get("options", []))
                self.assertNotEqual(0, result.returncode, result.stdout)
                self.assert_no_vm_update()
                self.assertEqual([], list(self.storage_dir.iterdir()))
                for key in behavior:
                    if key not in ("config", "options"):
                        self.state.pop(key, None)

    def test_failed_attach_retains_generated_iso_for_inspection(self) -> None:
        """Keep the finished artifact if a Proxmox update fails ambiguously."""
        self.state["fail"] = "qm set"
        self.save_state()
        result = self.run_cli()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("generated ISO retained", result.stderr)
        self.assertEqual(1, len(list(self.storage_dir.glob("*.iso"))))
        self.assertEqual([], list(self.storage_dir.glob(".*")))

    def test_web_mode_refuses_a_competing_local_seed(self) -> None:
        """Avoid silently leaving a local seed active when selecting a web seed."""
        self.state["config"] += "\nide3: local:iso/autoinstall-seed-103-" + "a" * 32 + ".iso,media=cdrom"
        self.save_state()
        result = self.run_cli(static=False)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Detach the generated local seed", result.stderr)
        self.assert_no_vm_update()


if __name__ == "__main__":
    unittest.main()
