"""Check the installed sender's recovery and visible Stop control on the selected phone."""
from __future__ import annotations

import asyncio
import json
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

from verify_sender import Viewer, wait_for_frames, PROJECT
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from phone import phone, PACKAGE

PHONE_TOOL = Path(__file__).resolve().parents[1] / "tools/phone.py"


def action(*arguments: str) -> None:
    subprocess.run(["/usr/bin/python3", str(PHONE_TOOL), *arguments], check=True)


async def main() -> None:
    config = json.loads((PROJECT / "local/android-sender-check/pairing.json").read_text())
    output = PROJECT / "local/android-sender-check/lifecycle-report.json"
    report = {"status": "running", "checks": [], "real_reboot_tested": False}
    device, identifier = phone()
    shell = ["-s", identifier, "shell"]
    viewer = Viewer(config)
    try:
        await viewer.discover()
        old_pid = device.adb(shell + ["pidof", PACKAGE])
        device.adb(shell + ["run-as", PACKAGE, "kill", "-9", old_pid])
        deadline = time.monotonic() + 35
        state = None
        while time.monotonic() < deadline:
            try:
                state = await viewer.status()
                break
            except Exception:
                await asyncio.sleep(1)
        assert state is not None and state["running"] and not state["armed"] and not state["viewer"]
        assert not state["video"] and not state["microphone"] and not state["audio_input_active"]
        new_pid = device.adb(shell + ["pidof", PACKAGE])
        assert old_pid != new_pid
        code, _ = await viewer.request("/v1/offer", {})
        assert code == 403
        report["checks"].append("OS recreates sticky listener after process death without restarting sensors")
        print("Process recovery returned the listener with sensors disabled.", flush=True)
        action("launch"); action("tap", "--label", "Enable Sender")
        await asyncio.sleep(2)
        assert (await viewer.status())["armed"]
        report["checks"].append("local Enable rearms camera and microphone availability")
        await viewer.connect()
        await wait_for_frames(viewer, ["video", "audio"])
        action("tap", "--label", "Stop Sender")
        await asyncio.sleep(2)
        before = dict(viewer.counts)
        await asyncio.sleep(5)
        assert viewer.counts == before, "Media continues after Stop."
        service = device.adb(shell + ["dumpsys", "activity", "services", PACKAGE])
        assert "isForeground=true" not in service, "Foreground service remains after Stop."
        prefs = device.adb(shell + ["run-as", PACKAGE, "cat", "shared_prefs/sender.xml"])
        enabled = next(n.attrib["value"] for n in ET.fromstring(prefs) if n.attrib["name"] == "enabled")
        assert enabled == "false", "Stop did not revoke restart permission."
        power = device.adb(shell + ["dumpsys", "power"])
        assert "Wake Locks:" in power, "Active wake-lock section unavailable."
        active_wakes = power.split("Wake Locks:", 1)[1].split("\n\n", 1)[0]
        assert "AndroidSender:Available" not in active_wakes, "Sender wake lock remains after Stop."
        report["checks"].append("visible Stop ends real media, foreground service, wake lock and restart permission")
        viewer.session = ""
        await viewer.close()
        viewer = Viewer(config)
        action("tap", "--label", "Enable Sender")
        await asyncio.sleep(3)
        await viewer.discover()
        state = await viewer.status()
        assert state["armed"] and not state["viewer"] and not state["video"] and not state["microphone"]
        report["checks"].append("explicit Enable restores a ready sender with sensors off")
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", error_type=type(error).__name__, error=str(error) if isinstance(error, AssertionError) else "Check failed.")
        raise
    finally:
        await viewer.close()
        output.write_text(json.dumps(report, indent=2)); output.chmod(0o600)
        print(json.dumps(report), flush=True)


if __name__ == "__main__":
    try: asyncio.run(main())
    except Exception as failure:
        print("Lifecycle check failed: " + type(failure).__name__, file=sys.stderr)
        sys.exit(1)
