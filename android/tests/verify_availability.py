"""Start real input from standby with the screen off, then prove heartbeat expiry."""
from __future__ import annotations

import asyncio
import contextlib
import json
import sys
import time
from pathlib import Path

from verify_sender import Viewer, wait_for_frames, PROJECT
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from phone import phone


async def main() -> None:
    config = json.loads((PROJECT / "local/android-sender-check/pairing.json").read_text())
    output = PROJECT / "local/android-sender-check/availability-report.json"
    report = {"status": "running", "checks": [], "media_saved": False}
    device, identifier = phone(); shell = ["-s", identifier, "shell"]
    viewer = Viewer(config)
    asleep = False
    try:
        state = await viewer.discover()
        assert state["armed"] and not state["viewer"]
        device.adb(shell + ["input", "keyevent", "KEYCODE_HOME"])
        device.adb(shell + ["input", "keyevent", "KEYCODE_SLEEP"]); asleep = True
        await asyncio.sleep(8)
        await viewer.connect(tailnet_only=True)
        await wait_for_frames(viewer, ["video", "audio"])
        before = dict(viewer.counts)
        await asyncio.sleep(5)
        assert viewer.counts["video"] > before["video"] + 10 and viewer.counts["audio"] > before["audio"] + 20
        report["checks"].append("new Tailscale-only viewer starts both sensors from standby with the screen off")
        print("Screen-off standby accepted a new viewer and delivered both inputs.", flush=True)
        viewer.heartbeat.cancel()
        with contextlib.suppress(asyncio.CancelledError): await viewer.heartbeat
        viewer.heartbeat = None
        deadline = time.monotonic() + 55
        while time.monotonic() < deadline:
            state = await viewer.status()
            if not state["viewer"]: break
            await asyncio.sleep(2)
        assert not state["viewer"] and not state["video"] and not state["microphone"]
        await asyncio.sleep(2)
        assert not (await viewer.status())["audio_input_active"] and state["armed"]
        report["checks"].append("missing heartbeat releases real sensors and leaves the listener ready")
        viewer.session = ""
        report.update(status="passed", received_frames=viewer.counts)
    except Exception as error:
        report.update(status="failed", error_type=type(error).__name__)
        raise
    finally:
        await viewer.close()
        if asleep: device.adb(shell + ["input", "keyevent", "KEYCODE_WAKEUP"])
        output.write_text(json.dumps(report, indent=2)); output.chmod(0o600)
        print(json.dumps(report), flush=True)


if __name__ == "__main__":
    try: asyncio.run(main())
    except Exception as failure:
        print("Availability check failed: " + type(failure).__name__, file=sys.stderr)
        sys.exit(1)
