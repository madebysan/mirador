"""Trust selection checks with synthetic identities; no phone connection is made."""
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("sender_phone", Path(__file__).resolve().parents[1] / "tools/phone.py")
sender_phone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sender_phone)


class PhoneIdentityTests(unittest.TestCase):
    def device(self, folder: Path):
        file = folder / "device.json"
        file.write_text(json.dumps({"serial": "expected-test-identity"}))
        return sender_phone.SenderDevice(file)

    def test_selects_only_the_saved_stable_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            device = self.device(Path(folder))

            def responses(arguments, timeout=5):
                if arguments == ["devices"]:
                    return "List of devices attached\nother-test-device device\nexpected-test-device device"
                return "expected-test-identity" if arguments[1] == "expected-test-device" else "different-test-identity"

            with patch.object(device, "adb", side_effect=responses):
                self.assertEqual(device.connect(), "expected-test-device")

    def test_an_authorized_device_with_a_different_identity_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            device = self.device(Path(folder))
            with patch.object(device, "adb", side_effect=["List of devices attached\nother-test-device device", "different-test-identity"]):
                with self.assertRaisesRegex(ValueError, "verified Android phone is not connected"):
                    device.connect()

    def test_missing_trust_configuration_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ValueError, "trusted Android setup is missing"):
                sender_phone.SenderDevice(Path(folder) / "missing.json")


if __name__ == "__main__":
    unittest.main()
