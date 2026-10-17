"""Use the project's verified phone; never print identifiers or pairing credentials."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
EXPERIMENT = Path(__file__).resolve().parents[1]
PACKAGE = "com.san.androidsender"
ADB = os.environ.get("ANDROID_SENDER_ADB", "/opt/homebrew/bin/adb")


class SenderDevice:
    """Select only this project's previously verified Android identity."""

    def __init__(self, configuration: Path | None = None):
        self.path = configuration or PROJECT / "local/android-sender-check/device.json"
        try:
            self.config = json.loads(self.path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError("The mobile project's trusted Android setup is missing.") from error
        if not isinstance(self.config, dict) or not isinstance(self.config.get("serial"), str) or not self.config["serial"]:
            raise ValueError("The mobile project's trusted Android identity is missing.")

    def adb(self, arguments: list[str], timeout: float = 5) -> str:
        try:
            result = subprocess.run([ADB, *arguments], capture_output=True, text=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ValueError("Android did not respond. Check its authorized debugging connection.") from error
        if result.returncode:
            raise ValueError("Android is unavailable. Check its authorized debugging connection.")
        return result.stdout.strip()

    def connect(self) -> str:
        available = []
        for line in self.adb(["devices"]).splitlines():
            fields = line.split()
            if len(fields) >= 2 and fields[1] == "device": available.append(fields[0])
        candidates = []
        for key in ["tailscaleEndpoint", "wifiEndpoint"]:
            endpoint = self.config.get(key)
            if not isinstance(endpoint, str) or not endpoint: continue
            if endpoint not in available:
                try: self.adb(["connect", endpoint], 3)
                except ValueError: continue
            candidates.append(endpoint)
        candidates.extend(available)
        for identifier in dict.fromkeys(candidates):
            try:
                serial = self.adb(["-s", identifier, "shell", "getprop", "ro.serialno"], 3)
                if serial == self.config["serial"]: return identifier
            except ValueError: continue
        raise ValueError("The mobile project's verified Android phone is not connected. No device was paired or selected.")


def phone() -> tuple[SenderDevice, str]:
    device = SenderDevice()
    identifier = device.connect()
    model = device.adb(["-s", identifier, "shell", "getprop", "ro.product.model"])
    api = device.adb(["-s", identifier, "shell", "getprop", "ro.build.version.sdk"])
    if model != "A065" or api != "34":
        raise ValueError("This check expects the verified Nothing A065 / Android 14.")
    return device, identifier


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "launch", "grant", "pairing", "tap", "status", "home", "sleep", "wake"])
    parser.add_argument("--label", help="Exact Android Sender button label for tap")
    options = parser.parse_args()
    device, identifier = phone()
    prefix = ["-s", identifier, "shell"]
    if options.action == "install":
        apk = EXPERIMENT / "app/build/outputs/apk/debug/app-debug.apk"
        if not apk.is_file(): raise ValueError("Build the APK first.")
        device.adb(["-s", identifier, "install", "-r", str(apk)], 90)
        print("Installed Android Sender on the verified Nothing phone.")
    elif options.action == "grant":
        for permission in ["CAMERA", "RECORD_AUDIO", "POST_NOTIFICATIONS"]:
            device.adb(prefix + ["pm", "grant", PACKAGE, "android.permission." + permission])
        print("Granted this app camera, microphone and notification permissions.")
    elif options.action == "launch":
        device.adb(prefix + ["am", "start", "-n", PACKAGE + "/.MainActivity"])
        print("Opened Android Sender.")
    elif options.action == "pairing":
        raw = device.adb(prefix + ["run-as", PACKAGE, "cat", "shared_prefs/sender.xml"])
        values = {item.attrib["name"]: item.text for item in ET.fromstring(raw) if item.tag == "string"}
        data = {"endpoints": json.loads(values["endpoints"]), "token": values["token"], "certificate_sha256": values["fingerprint"]}
        folder = PROJECT / "local/android-sender-check"
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / "pairing.json"
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as output: json.dump(data, output)
        target.chmod(0o600)
        print("Saved private pairing data to ignored local validation storage.")
    elif options.action == "tap":
        if not options.label: raise ValueError("Pass the exact button label.")
        remote = "/data/local/tmp/android-sender-ui.xml"
        device.adb(prefix + ["uiautomator", "dump", remote], 12)
        raw = device.adb(prefix + ["cat", remote])
        nodes = [node for node in ET.fromstring(raw).iter("node")
                 if node.attrib.get("package") == PACKAGE and node.attrib.get("text", "").casefold() == options.label.casefold()]
        if len(nodes) != 1 or nodes[0].attrib.get("enabled") != "true": raise ValueError("Expected enabled Sender button not found.")
        import re
        x1, y1, x2, y2 = map(int, re.findall(r"\d+", nodes[0].attrib["bounds"]))
        device.adb(prefix + ["input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2)])
        print("Tapped " + options.label + ".")
    elif options.action == "status":
        pid = device.adb(prefix + ["pidof", PACKAGE])
        service = device.adb(prefix + ["dumpsys", "activity", "services", PACKAGE])
        print({"process_present": bool(pid), "foreground_service": "isForeground=true" in service})
    else:
        key = {"home": "KEYCODE_HOME", "sleep": "KEYCODE_SLEEP", "wake": "KEYCODE_WAKEUP"}[options.action]
        device.adb(prefix + ["input", "keyevent", key])
        print("Sent " + options.action + " to the verified phone.")


if __name__ == "__main__":
    try: main()
    except ValueError as error:
        print(str(error)); raise SystemExit(1)
