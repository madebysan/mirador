# Mirador for iPhone (receiver)

Back to the [README](../README.md).

The iPhone app shows the Android phone's rear or front camera, plays its microphone, and can turn on its rear light. It's SwiftUI on iOS 17 or later, with native WebRTC ([stasel/WebRTC](https://github.com/stasel/WebRTC) 150.0.0). The project, target and app identifier still use the old name, Android Viewer (`AndroidViewer.xcodeproj`, `com.san.androidviewer`), so existing installs keep their pairing.

## Build

You need a recent Xcode, an iPhone in Developer Mode and an Apple developer team (a free Apple account works, but its apps stop opening after 7 days until you build again).

1. Create `local/Signing.local.xcconfig` at the repository root with your team and a bundle ID of your own. Git ignores `local/`, and [Signing.xcconfig](Signing.xcconfig) includes the file when it exists:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   PRODUCT_BUNDLE_IDENTIFIER = com.yourname.mirador
   ```

2. Build from the repository root. The script runs the core tests, makes a signed device build and checks its signature:

   ```sh
   ios/script/build.sh
   ```

   Or open `ios/AndroidViewer.xcodeproj` in Xcode and run the `AndroidViewer` scheme on your iPhone.

3. Optional: to reach the Android phone from other networks through your own [relay](../relay/README.md), put `RELAY_URL=https://...` in `local/relay.env` before building. Without it the app uses Wi-Fi and Tailscale only.

`project.yml` (XcodeGen) generated the project; regenerating it means adding the WebRTC package link again.

## How it works

- **Pairing:** Pair Android Phone opens the camera only to scan the QR code from the Android app. The code holds the phone's private addresses, a random 256-bit key and its TLS certificate fingerprint. It's checked, then saved in a device-only keychain entry that doesn't sync or back up. Pairing doesn't start the camera or microphone.
- **Control:** every request uses HTTPS pinned to the scanned certificate, refuses redirects and goes only to private addresses (home network and Tailscale). Through the relay, requests are sealed end to end instead.
- **Finding the phone:** the app asks every paired address and the relay at once, and a private address wins if it answers. It checks again when the iPhone's network changes or the app returns to the foreground, without starting any input.
- **Media:** WebRTC with receive-only video and audio. The audio device only plays, so the app has no microphone permission. Video can be pinched to zoom from fit to 4× and dragged while zoomed; zoom only scales the received picture.
- **Light:** the flashlight key appears when the Android phone reports a rear flash, and works only while the rear camera is live. Switching lens, turning video off or Stop turns the light off.
- **Lifecycle:** Stop closes the connection and asks Android to release the camera and microphone. Leaving the app does the same and doesn't resume on its own. A brief network drop gets an 8-second grace period; after a real drop, Reconnect restores the previous camera and listening, only when tapped. An audio interruption stops only listening.

The screen is styled as a piece of hardware: an LCD with the state, link and elapsed time, physical keys with haptics, and a VU meter for the Android microphone. Its components are in [Hardware.swift](App/Hardware.swift). A Debug-only `--design-demo live|ready|offline` launch argument (plus `--design-landscape`) fills static states for checking layouts in the simulator, without any network or media; Release builds don't contain it.

## Tests

`swift test --package-path ios` runs the 18 core tests: pairing payloads, control replies, network rules, relay key and sealing vectors shared with Android, the light rules and zoom limits. `Tools/ViewerCheck` checks a real pinned HTTPS connection from the Mac and that a wrong fingerprint is refused.

`Tools/phone.py` is the maintainer's install and on-phone check helper. It only works with the maintainer's saved device setup under `local/`, so you can ignore it and install from Xcode.

## Limits

Tested on one iPhone 17 Pro with one Android phone. QR scanning in poor light, VoiceOver, audio route changes and long sessions haven't been checked in depth. `fastlane/` has lanes for internal TestFlight uploads; they need your own App Store Connect API key in `ios/fastlane/.env`.
