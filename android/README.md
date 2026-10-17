# Mirador for Android (transmitter)

Back to the [README](../README.md).

The Android app sends its rear or front camera and microphone to the paired iPhone. It's Java on Android 11 or later (arm64), running as a foreground service with a visible Stop button. The package name still uses the old name, `com.san.androidsender`, so existing installs keep their pairing.

## Build

You need JDK 17 and the Android SDK (compile SDK 35). The script builds a debug APK, runs the JVM tests and Android lint:

```sh
android/script/build.sh
```

It defaults to Homebrew's OpenJDK 17 and command-line tools; set `ANDROID_SENDER_JAVA_HOME` and `ANDROID_SENDER_SDK` to use others. The APK is `android/app/build/outputs/apk/debug/app-debug.apk`, signed with your own Android debug key. Install it with `adb install -r` and open Mirador.

Optional: to use your own [relay](../relay/README.md), put `RELAY_URL=https://...` in `local/relay.env` before building.

Dependencies: [webrtc-sdk/android](https://github.com/webrtc-sdk/android) 150.7871.01, ZXing 3.5.3 for the pairing QR code and OkHttp 4.12.0 for the relay WebSocket. Their licenses ship in `app/src/main/assets/licenses/`.

## Using it

1. Open Mirador, allow camera, microphone and notifications, and tap **Enable**.
2. Allow it to run in the background, and keep the phone charging if it will watch for a long time.
3. Tap **Pair a Receiver** and scan the code with the iPhone app. The code window blocks screenshots; never share it, because it grants live access while Mirador is enabled. Pairing data is left out of Android backups and device transfer.
4. Leave the app. The notification shows when Mirador is ready or live, and has **Stop**.

Waiting doesn't open the camera or microphone; only a request from the paired iPhone does. Turning the microphone off stops its input rather than muting it. If the iPhone goes away, a missed heartbeat ends its 45-second lease and releases both. Stop closes the listener and keeps Mirador off until you enable it again. After a reboot or if Android restarts the app, the listener can come back, but the camera and microphone need a local Enable.

## Control API

The phone listens with HTTPS on port 8443, only on private addresses (home Wi-Fi, Ethernet and VPN, private IPv4 ranges and IPv6 ULA). Every route needs `Authorization: Bearer <pairing key>`; the receiver must check the certificate fingerprint from the QR code first. The relay carries the same requests sealed end to end.

| Route | Request and result |
| --- | --- |
| `GET /v1/status` | Readiness, input and connection state, counters, `torch_available` and generic errors. Never credentials or SDP. |
| `POST /v1/offer` | Non-trickle offer SDP with receive-only video and audio, `camera` (`rear` or `front`), `video` and `microphone`. Returns the answer, a session ID and heartbeat timing. A second receiver gets 409. |
| `POST /v1/control` | `session`, plus any of `camera`, `video`, `microphone` and `torch`. `torch` works only with the rear camera live. |
| `POST /v1/ping` | `session`, every 10 seconds while watching. |
| `POST /v1/disconnect` | `session`; releases the camera and microphone and stays ready. |

Expired sessions get 409, a sender that needs a local Enable gets 403 and a wrong key gets 401. Direct sessions keep only private media addresses; relayed sessions may use Cloudflare STUN and TURN and cellular addresses. Media is encrypted by WebRTC (DTLS-SRTP).

**The light:** WebRTC's camera capturer has no torch control, and Android refuses `setTorchMode` while the camera is open. [CameraTorch](app/src/main/java/com/san/androidsender/CameraTorch.java) rebuilds the running Camera2 request with WebRTC's own settings plus `FLASH_MODE_TORCH`. It reads private fields of the pinned WebRTC build, and `CameraTorchTest` fails if an update renames them.

## Tests

The 13 JVM tests cover private address and interface rules, pairing keys, bounded HTTP parsing, relay sealing vectors shared with the iPhone, removal of public media addresses and the WebRTC fields the light needs.

`tools/phone.py` and the device checks in `tests/` are the maintainer's tools for one specific phone. They need a saved device identity in `local/android-sender-check/device.json` and refuse any other phone, so you can ignore them.

## Limits

Tested on one Nothing phone with Android 14. Android can still end the app, and reboot, overnight use, forced Doze and cellular-only use are untested. The target SDK stays at 34, and the build is arm64 only.

See Android's notes on [foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types) and [background start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start).
