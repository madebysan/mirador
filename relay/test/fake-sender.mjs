// Stand-in Android sender for local protocol checks. Implements the same room/key derivation and sealing as
// RelayCrypto.java, answers sealed /v1/status requests, and exits after one reply.
// Usage: node relay/test/fake-sender.mjs http://127.0.0.1:8787 <base64url token>
import { createHmac, hkdfSync, createDecipheriv, createCipheriv, randomBytes } from "node:crypto";
const [base, token] = process.argv.slice(2);
const secret = Buffer.from(token, "base64url");
const room = createHmac("sha256", secret).update("android-viewer/room/v1").digest("hex");
const key = (info) => Buffer.from(hkdfSync("sha256", secret, "android-viewer/relay/v1", info, 32));
const fromViewer = key("viewer-to-sender"), toViewer = key("sender-to-viewer");
const socket = new WebSocket(`${base.replace(/^http/, "ws")}/v1/room/${room}/sender`);
socket.onmessage = (event) => {
  const box = Buffer.from(JSON.parse(event.data).box, "base64");
  const decipher = createDecipheriv("aes-256-gcm", fromViewer, box.subarray(0, 12));
  decipher.setAuthTag(box.subarray(box.length - 16));
  const request = JSON.parse(Buffer.concat([decipher.update(box.subarray(12, box.length - 16)), decipher.final()]));
  const body = request.path === "/v1/status"
    ? { armed: true, running: true, viewer: false, video: false, microphone: false, camera: "rear", connection: "idle",
        audio_input_active: false, video_frames: 0, audio_samples: 0, error: "" }
    : { error: "not supported" };
  const reply = JSON.stringify({ id: request.id, code: request.path === "/v1/status" ? 200 : 404, body, ts: Date.now() });
  const nonce = randomBytes(12), cipher = createCipheriv("aes-256-gcm", toViewer, nonce);
  const sealed = Buffer.concat([nonce, cipher.update(reply), cipher.final(), cipher.getAuthTag()]);
  socket.send(JSON.stringify({ box: sealed.toString("base64") }));
  console.log(`fake sender answered ${request.method} ${request.path}`);
  setTimeout(() => process.exit(0), 300);
};
socket.onopen = () => console.log("fake sender connected");
