// Local check against `wrangler dev`: presence, forwarding in both directions, role replacement and ICE fallback.
// Usage: node relay/test/relay.test.mjs http://127.0.0.1:8787
const base = process.argv[2] ?? "http://127.0.0.1:8787";
const room = "ab".repeat(32);
const socketURL = (role) => `${base.replace(/^http/, "ws")}/v1/room/${room}/${role}`;

function open(role) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(socketURL(role));
    socket.frames = [];
    socket.waiters = [];
    socket.onmessage = (event) => {
      const waiter = socket.waiters.shift();
      if (waiter) waiter(event.data); else socket.frames.push(event.data);
    };
    socket.onopen = () => resolve(socket);
    socket.onerror = () => reject(new Error(`${role} could not connect`));
  });
}
const next = (socket) => socket.frames.length ? Promise.resolve(socket.frames.shift())
  : new Promise((resolve, reject) => { socket.waiters.push(resolve); setTimeout(() => reject(new Error("timeout")), 3000); });
const assert = (condition, label) => { if (!condition) throw new Error(`FAILED: ${label}`); console.log(`ok - ${label}`); };

const viewer = await open("viewer");
assert(JSON.parse(await next(viewer)).sender === false, "viewer sees the sender offline");
const sender = await open("sender");
assert(JSON.parse(await next(viewer)).sender === true, "viewer is told when the sender comes online");
viewer.send("sealed-request");
assert(await next(sender) === "sealed-request", "viewer frame reaches the sender unchanged");
sender.send("sealed-response");
assert(await next(viewer) === "sealed-response", "sender frame reaches the viewer unchanged");
viewer.send("ping");
assert(await next(viewer) === "pong", "keepalive ping is answered by the relay");
const replacement = await open("sender");
await new Promise((r) => setTimeout(r, 300));
viewer.send("after-replace");
assert(await next(replacement) === "after-replace", "a reconnecting sender replaces the stale one");
replacement.close();
await new Promise((r) => setTimeout(r, 300));
const presence = viewer.frames.map((f) => JSON.parse(f)).filter((f) => f.relay === "presence").pop();
assert(presence && presence.sender === false, "viewer is told when the sender goes offline");
const ice = await (await fetch(`${base}/v1/room/${room}/ice`, { method: "POST" })).json();
assert(ice.iceServers[0].urls[0] === "stun:stun.cloudflare.com:3478", "ICE falls back to Cloudflare STUN without TURN secrets");
assert((await fetch(`${base}/v1/room/not-a-room/viewer`)).status === 404, "malformed room IDs are rejected");
viewer.close(); sender.close();
process.exit(0);
