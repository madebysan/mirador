# Internet relay

Back to the [README](../README.md).

A small Cloudflare Worker that lets the [iPhone receiver](../ios/README.md) reach the [Android transmitter](../android/README.md) when the phones aren't on the same Wi-Fi or Tailscale network. It's optional: without it, Mirador works on Wi-Fi and Tailscale only.

## What it sees

- Each pair of phones meets in a room named by a 64-character ID derived from the pairing key. The key never leaves the phones, and no extra pairing is needed.
- The Android phone keeps one outgoing WebSocket to its room, so nothing on the phone listens on the internet. The iPhone joins the same room while the app is open.
- Every request and reply is sealed end to end with AES-GCM, one key per direction, derived from the pairing key. The relay can't read, forge or reflect them, and the Android phone rejects stale or repeated requests. Because the WebRTC offer and answer travel sealed, the relay can't interfere with the media encryption either.
- The only thing the relay can tell is whether the Android phone is connected. It stores and logs nothing.
- Video and audio go directly between the phones when their networks allow it, using Cloudflare STUN. With TURN configured, media can fall back to Cloudflare's TURN relay, still encrypted end to end.
- Wi-Fi and Tailscale keep priority; the phones use the relay only when no private path answers.

## Run your own

You need a Cloudflare account and [Wrangler](https://developers.cloudflare.com/workers/wrangler/).

```sh
cd relay
wrangler deploy
```

Put the Worker's address in `local/relay.env` at the repository root as `RELAY_URL=https://...`, then rebuild both apps; their build scripts read it. Git ignores `local/`.

TURN is optional. Create a Cloudflare Realtime TURN key and add it as two Worker secrets, `TURN_KEY_ID` and `TURN_KEY_API_TOKEN` (`wrangler secret put`). Cloudflare charges for relayed TURN traffic (see its [TURN pricing](https://developers.cloudflare.com/realtime/turn/)). Without the secrets, the relay hands out STUN only, which is free.

Before you turn TURN on, know that the endpoint that hands out TURN credentials doesn't check pairing: anyone who learns your Worker's address could request credentials and use your TURN allowance.

## Checks

`test/relay.test.mjs` runs against `wrangler dev --local` and covers presence, forwarding both ways, replacing a reconnecting phone, keepalive, the STUN fallback and malformed rooms. `test/fake-sender.mjs` is a stand-in Android phone with its own Node implementation of the sealing; with the iPhone's `ViewerCheck <pairing> --relay <url>`, it proves a sealed round trip. Both apps test the same key and sealing vectors.
