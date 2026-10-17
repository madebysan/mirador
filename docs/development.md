Back to the [README](../README.md).

# Development notes

How the repository is laid out, how to build Mirador on your own phones, and what has been tested.

## Layout

- [ios/](../ios/README.md): the iPhone receiver (SwiftUI, native WebRTC, certificate-pinned control, device-only pairing).
- [android/](../android/README.md): the Android transmitter (Java, WebRTC, foreground service with a visible Stop).
- [relay/](../relay/README.md): the optional Cloudflare Worker for phones on different networks.

Mirador was called Android Viewer until October 2026. Project, folder and app identifiers keep the old name so existing installs keep their pairing: the iPhone app is `com.san.androidviewer` and the Android app is `com.san.androidsender`. When you build your own iPhone app, use your own bundle ID (below).

## Build it yourself

You need an iPhone with iOS 17 or later, an Android phone with Android 11 or later (arm64), a Mac with a recent Xcode, JDK 17 and the Android SDK.

1. **iPhone:** create `local/Signing.local.xcconfig` with your Apple team ID and a bundle ID of your own, then run `ios/script/build.sh` or build in Xcode. Details are in the [iPhone README](../ios/README.md#build). A free Apple account works, but its builds stop opening after 7 days.
2. **Android:** run `android/script/build.sh` and install the APK with `adb install -r`. Details are in the [Android README](../android/README.md#build).
3. **Pair:** on Android, tap Enable, then Pair a Receiver; on the iPhone, tap Pair Android Phone and scan the code.
4. **Optional relay:** to watch from another network without Tailscale, deploy your own [relay](../relay/README.md) and put its address in `local/relay.env` before building both apps. Otherwise, install Tailscale on both phones, or keep them on the same Wi-Fi.

Everything under `local/` (signing, relay address, pairing files, test reports and build caches) and `dist/` (personal builds) is ignored by Git and stays on your Mac.

## Tests

- iPhone: 18 core tests (`swift test --package-path ios`), run by `ios/script/build.sh` before the signed build and signature check.
- Android: 13 JVM tests plus Android lint, run by `android/script/build.sh`.
- Relay: `relay/test/relay.test.mjs` against `wrangler dev --local`.

The device scripts (`ios/Tools/phone.py`, `android/tools/phone.py` and `android/tests/`) are the maintainer's tools for two specific phones. They read device identities from `local/` and refuse any other phone.

## What has been tested

On one iPhone 17 Pro and one Nothing phone with Android 14: live video and audio, switching cameras, turning video and listening off separately, Stop, pinch to zoom, the rear light, background and screen-off use on Android, recovery after Android ends the app, and viewing through the relay with the iPhone off Wi-Fi.

Not tested yet: a real reboot, overnight use, forced Doze, cellular-only use, and pairing through the relay alone with the Android phone on mobile data.
