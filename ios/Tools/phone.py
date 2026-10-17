"""Install this viewer only on the verified iPhone, without printing identifiers or pairing data."""
from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
LOCAL = PROJECT / "local/iphone-viewer-check"
SIGNING = PROJECT / "local/Signing.local.xcconfig"


def signing_setting(name: str, default: str | None = None) -> str | None:
    """Reads one setting from the ignored local signing file that the Xcode build includes."""
    if SIGNING.is_file():
        for line in SIGNING.read_text().splitlines():
            key, _, value = line.partition("=")
            if key.strip() == name and value.strip(): return value.strip()
    return default


BUNDLE = signing_setting("PRODUCT_BUNDLE_IDENTIFIER", "com.san.androidviewer")
APP = LOCAL / "SignedBuild/Build/Products/Debug-iphoneos/AndroidViewer.app"


def command(arguments: list[str], label: str, timeout: int = 45) -> dict:
    output = LOCAL / (label + ".json")
    prefix_count = 2 if arguments[0] == "list" else 3
    control = ["--quiet", "--timeout", str(timeout), "--json-output", str(output)]
    result = subprocess.run(["xcrun", "devicectl", *arguments[:prefix_count], *control, *arguments[prefix_count:]],
                            capture_output=True, text=True, timeout=timeout + 5)
    (LOCAL / (label + ".log")).write_text(result.stdout + result.stderr)
    (LOCAL / (label + ".log")).chmod(0o600)
    if output.exists(): output.chmod(0o600)
    if result.returncode: raise RuntimeError(label + " failed. Details remain in ignored local validation storage.")
    return json.loads(output.read_text())


def selected_phone() -> dict:
    data = command(["list", "devices"], "devices", 15)
    devices = [device for device in data["result"]["devices"]
               if device.get("hardwareProperties", {}).get("marketingName") == "iPhone 17 Pro"
               and device.get("deviceProperties", {}).get("developerModeStatus") == "enabled"]
    if len(devices) != 1: raise RuntimeError("The verified iPhone is not uniquely available. Connect and unlock it.")
    phone = devices[0]
    decoded = subprocess.run(["/usr/bin/security", "cms", "-D", "-i", str(APP / "embedded.mobileprovision")], capture_output=True)
    if decoded.returncode: raise RuntimeError("Build and sign the viewer before checking device provisioning.")
    profile = plistlib.loads(decoded.stdout)
    team = signing_setting("DEVELOPMENT_TEAM")
    if not team or profile.get("TeamIdentifier") != [team]:
        raise RuntimeError("The signed app is not in the expected development team.")
    if phone["hardwareProperties"].get("udid") not in profile.get("ProvisionedDevices", []):
        raise RuntimeError("The existing development profile does not cover this phone.")
    return phone


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["discover", "install", "pair", "launch", "self-check", "report"])
    options = parser.parse_args()
    phone = selected_phone()
    if options.action == "discover":
        print({"model": phone["hardwareProperties"]["marketingName"],
               "os": phone["deviceProperties"]["osVersionNumber"],
               "connection": phone["connectionProperties"]["tunnelState"], "profile_covers_phone": True})
        return
    if phone.get("connectionProperties", {}).get("tunnelState") == "unavailable":
        raise RuntimeError("The iPhone is unavailable. Connect it by USB, unlock it, and tap Trust if requested.")
    device = ["--device", phone["identifier"]]
    if options.action == "install":
        if not APP.is_dir(): raise RuntimeError("Build and sign the viewer first.")
        command(["device", "install", "app", *device, str(APP)], "install", 90)
        print("Installed Android Viewer on the verified iPhone.")
    elif options.action == "pair":
        command(["device", "copy", "to", *device, "--source", str(LOCAL / "pairing.json"),
                 "--destination", "Library/Caches/PairingBootstrap.json", "--domain-type", "appDataContainer",
                 "--domain-identifier", BUNDLE], "private-pairing-transfer")
        print("Transferred private pairing data to this app's unbacked cache for one-time import.")
    elif options.action in ["launch", "self-check"]:
        arguments = ["device", "process", "launch", *device, "--terminate-existing", BUNDLE]
        if options.action == "self-check": arguments += ["--", "--pairing-bootstrap", "--self-check"]
        command(arguments, "launch")
        print("Started viewer" + (" self-check." if options.action == "self-check" else "."))
    else:
        report = LOCAL / "iphone-self-check.json"
        command(["device", "copy", "from", *device, "--source", "Library/Caches/ViewerSelfCheck.json",
                 "--destination", str(report), "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE], "report-transfer")
        print(json.dumps(json.loads(report.read_text())))


if __name__ == "__main__":
    try: main()
    except subprocess.TimeoutExpired:
        print("The phone command timed out. Connect and unlock the iPhone, then retry.")
        raise SystemExit(1)
    except RuntimeError as error:
        print(str(error)); raise SystemExit(1)
