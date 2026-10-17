"""Receive and discard real WebRTC media locally; report counts, never pixels or PCM."""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import ipaddress
import subprocess
import sys
import time
from pathlib import Path

import aiohttp
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from phone import phone, ADB, PACKAGE


class Viewer:
    def __init__(self, config: dict):
        self.config = config
        self.pin = aiohttp.Fingerprint(bytes.fromhex(config["certificate_sha256"]))
        self.http = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30))
        self.endpoint = ""
        self.session = ""
        self.peer = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        self.counts = {"video": 0, "audio": 0}
        self.first = {}
        self.dimensions = None
        self.readers = []
        self.heartbeat = None
        self.peer.on("track", self.receive)

    async def request(self, path: str, body: dict | None = None, authorized: bool = True) -> tuple[int, dict]:
        headers = {"Authorization": "Bearer " + self.config["token"]} if authorized else {}
        method = "GET" if body is None else "POST"
        async with self.http.request(method, self.endpoint + path, headers=headers,
                                     ssl=self.pin, json=body) as response:
            return response.status, await response.json()

    async def discover(self) -> dict:
        endpoints = sorted(self.config["endpoints"], key=lambda address: 0 if "[fd" in address else 1 if "100." in address else 2)
        for endpoint in endpoints:
            self.endpoint = endpoint
            try:
                code, state = await asyncio.wait_for(self.request("/v1/status"), 8)
                if code == 200:
                    print("Pinned private HTTPS connection established.", flush=True)
                    return state
            except (aiohttp.ClientError, TimeoutError):
                continue
        raise RuntimeError("No paired private endpoint responded.")

    def receive(self, track) -> None:
        async def consume() -> None:
            try:
                while True:
                    frame = await track.recv()
                    self.counts[track.kind] += 1
                    self.first.setdefault(track.kind, time.monotonic())
                    if track.kind == "video": self.dimensions = [frame.width, frame.height]
                    # No conversion, inspection, playback or file write of media.
            except Exception:
                return
        self.readers.append(asyncio.create_task(consume()))

    async def connect(self, video: bool = True, microphone: bool = True, camera: str = "rear", tailnet_only: bool = False) -> None:
        self.peer.addTransceiver("video", direction="recvonly")
        self.peer.addTransceiver("audio", direction="recvonly")
        await self.peer.setLocalDescription(await self.peer.createOffer())
        offer = self.peer.localDescription
        sdp = tailnet_candidates(offer.sdp) if tailnet_only else offer.sdp
        code, answer = await self.request("/v1/offer", {"type": offer.type, "sdp": sdp,
                                           "video": video, "microphone": microphone, "camera": camera})
        if code != 200: raise RuntimeError(answer.get("error", "Offer failed."))
        self.session = answer["session"]
        answer_sdp = tailnet_candidates(answer["sdp"]) if tailnet_only else answer["sdp"]
        await self.peer.setRemoteDescription(RTCSessionDescription(sdp=answer_sdp, type=answer["type"]))
        async def keepalive() -> None:
            while True:
                await asyncio.sleep(10)
                try: code, _ = await self.request("/v1/ping", {"session": self.session})
                except (aiohttp.ClientError, TimeoutError): return
                if code != 200: return
        self.heartbeat = asyncio.create_task(keepalive())

    async def control(self, **options) -> dict:
        code, state = await self.request("/v1/control", {"session": self.session, **options})
        if code != 200: raise RuntimeError(state.get("error", "Control failed."))
        return state

    async def status(self) -> dict:
        code, state = await self.request("/v1/status")
        if code != 200: raise RuntimeError("Status failed.")
        return state

    async def close(self, disconnect: bool = True) -> None:
        if self.heartbeat:
            self.heartbeat.cancel()
            with contextlib.suppress(asyncio.CancelledError, aiohttp.ClientError, TimeoutError): await self.heartbeat
        if disconnect and self.session:
            with contextlib.suppress(aiohttp.ClientError, TimeoutError):
                await self.request("/v1/disconnect", {"session": self.session})
        await self.peer.close()
        for reader in self.readers: reader.cancel()
        await asyncio.gather(*self.readers, return_exceptions=True)
        await self.http.close()


async def wait_for_frames(viewer: Viewer, kinds: list[str], seconds: float = 20) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if all(viewer.counts[kind] >= 5 for kind in kinds): return
        await asyncio.sleep(.2)
    raise AssertionError("Requested media did not arrive.")


def tailnet_candidates(sdp: str) -> str:
    lines = []
    candidates = 0
    network = ipaddress.ip_network("fd7a:115c:a1e0::/48")
    for line in sdp.splitlines():
        if line.startswith("a=candidate:"):
            parts = line.split()
            try: allowed = len(parts) > 4 and ipaddress.ip_address(parts[4]) in network
            except ValueError: allowed = False
            if not allowed: continue
            candidates += 1
        lines.append(line)
    if candidates == 0: raise RuntimeError("No Tailscale IPv6 media candidate is available.")
    return "\r\n".join(lines) + "\r\n"


async def check(config: dict, output: Path, screen_off: bool, tailnet_only: bool) -> None:
    viewer = Viewer(config)
    report = {"status": "running", "checks": [], "media_saved": False, "tailnet_only_candidates": tailnet_only}
    device, identifier = phone()
    shell = ["-s", identifier, "shell"]
    asleep = False
    try:
        state = await viewer.discover()
        assert state["armed"] and not state["viewer"] and not state["video"] and not state["microphone"]
        code, _ = await viewer.request("/v1/status", authorized=False)
        assert code == 401
        bad_pin = aiohttp.Fingerprint(b"\x00" * 32)
        try:
            async with viewer.http.get(viewer.endpoint + "/v1/status", ssl=bad_pin):
                raise AssertionError("Wrong TLS certificate accepted.")
        except aiohttp.ServerFingerprintMismatch:
            pass
        report["checks"].append("pairing and certificate rejection")
        await viewer.connect(tailnet_only=tailnet_only)
        await wait_for_frames(viewer, ["video", "audio"])
        before = dict(viewer.counts)
        await asyncio.sleep(5)
        assert viewer.counts["video"] > before["video"] + 10 and viewer.counts["audio"] > before["audio"] + 20
        report["checks"].append("rear video and microphone received")
        print("Rear video and microphone received; checking independent switches.", flush=True)
        await viewer.control(microphone=False)
        await asyncio.sleep(2)
        muted = await viewer.status()
        assert not muted["microphone"] and not muted["audio_input_active"]
        before = dict(viewer.counts)
        samples = muted["audio_samples"]
        await asyncio.sleep(4)
        state = await viewer.status()
        assert viewer.counts["video"] > before["video"] + 5 and state["audio_samples"] == samples
        report["checks"].append("microphone off releases input while video continues")
        await viewer.control(video=False, microphone=True)
        await asyncio.sleep(2)
        state = await viewer.status(); frames = state["video_frames"]; samples = state["audio_samples"]
        await asyncio.sleep(4)
        state = await viewer.status()
        assert not state["video"] and state["video_frames"] == frames and state["audio_samples"] > samples
        report["checks"].append("camera off while microphone continues")
        await viewer.control(video=True, camera="front")
        before = dict(viewer.counts)
        await asyncio.sleep(6)
        state = await viewer.status()
        assert state["camera"] == "front" and viewer.counts["video"] > before["video"] + 10 and state["microphone"]
        await viewer.control(camera="rear")
        before = dict(viewer.counts)
        await asyncio.sleep(5)
        assert viewer.counts["video"] > before["video"] + 10
        report["checks"].append("front and rear switching preserves microphone")
        code, _ = await viewer.request("/v1/control", {"session": "expired", "video": False})
        assert code == 409 and (await viewer.status())["video"]
        report["checks"].append("stale viewer cannot control current input")
        if screen_off:
            device.adb(shell + ["input", "keyevent", "KEYCODE_HOME"])
            device.adb(shell + ["input", "keyevent", "KEYCODE_SLEEP"]); asleep = True
            before = dict(viewer.counts)
            await asyncio.sleep(20)
            assert viewer.counts["video"] > before["video"] + 30 and viewer.counts["audio"] > before["audio"] + 100
            report["checks"].append("background and screen-off live media for 20 seconds")
            print("Background and screen-off stream passed.", flush=True)
        code, state = await viewer.request("/v1/disconnect", {"session": viewer.session})
        assert code == 200 and not state["viewer"]
        viewer.session = ""
        await asyncio.sleep(2)
        state = await viewer.status()
        assert not state["video"] and not state["microphone"] and not state["audio_input_active"] and state["armed"]
        report["checks"].append("disconnect releases sensors and leaves sender ready")
        report.update(status="passed", received_frames=viewer.counts, dimensions=viewer.dimensions)
    except Exception as error:
        report.update(status="failed", error_type=type(error).__name__, error=str(error) if isinstance(error, (AssertionError, RuntimeError)) else "Check failed.")
        raise
    finally:
        await viewer.close()
        if asleep: device.adb(shell + ["input", "keyevent", "KEYCODE_WAKEUP"])
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2)); output.chmod(0o600)
        print(json.dumps(report), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=PROJECT / "local/android-sender-check/pairing.json")
    parser.add_argument("--output", type=Path, default=PROJECT / "local/android-sender-check/stream-report.json")
    parser.add_argument("--screen-off", action="store_true")
    parser.add_argument("--tailnet-only", action="store_true")
    options = parser.parse_args()
    asyncio.run(check(json.loads(options.config.read_text()), options.output, options.screen_off, options.tailnet_only))


if __name__ == "__main__":
    try: main()
    except Exception as failure:
        print("Sender check failed: " + type(failure).__name__, file=sys.stderr)
        sys.exit(1)
