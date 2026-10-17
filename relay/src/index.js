// Android Viewer relay: a rendezvous for the Android sender and the iPhone viewer.
//
// Each room is named by a 64-hex-character ID that both apps derive from their pairing secret.
// The relay forwards opaque text frames between the room's one sender and one viewer. Frames are
// end-to-end encrypted and authenticated by the apps; the relay cannot read, forge or usefully replay
// them. It stores nothing and logs nothing. The only plain metadata it produces is sender presence.
import { DurableObject } from "cloudflare:workers";

const ROOM_PATH = /^\/v1\/room\/([0-9a-f]{64})\/(sender|viewer|ice)$/;
const MAX_FRAME = 65536;
const ALLOWED_ICE_URLS = new Set([
  "stun:stun.cloudflare.com:3478",
  "turn:turn.cloudflare.com:3478?transport=udp",
  "turns:turn.cloudflare.com:443?transport=tcp",
]);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(ROOM_PATH);
    if (!match) return new Response("Not found", { status: 404 });
    const [, room, action] = match;

    if (action === "ice") {
      if (request.method !== "POST") return new Response("Use POST", { status: 405 });
      return iceServers(env);
    }
    if (request.headers.get("Upgrade") !== "websocket") return new Response("WebSocket required", { status: 426 });
    const stub = env.ROOMS.get(env.ROOMS.idFromName(room));
    const forward = new URL(request.url);
    forward.searchParams.set("role", action);
    return stub.fetch(new Request(forward, request));
  },
};

/// Short-lived STUN/TURN settings. Without TURN secrets the relay still offers Cloudflare STUN,
/// which covers phones whose networks allow a direct path.
async function iceServers(env) {
  const stunOnly = [{ urls: ["stun:stun.cloudflare.com:3478"] }];
  if (!env.TURN_KEY_ID || !env.TURN_KEY_API_TOKEN) return json({ iceServers: stunOnly, turn: false });
  const response = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({ ttl: 14400 }),
  });
  if (!response.ok) return json({ iceServers: stunOnly, turn: false });
  const generated = await response.json();
  const servers = (generated.iceServers ?? [])
    .map((server) => ({ ...server, urls: [server.urls].flat().filter((entry) => ALLOWED_ICE_URLS.has(entry)) }))
    .filter((server) => server.urls.length > 0);
  return json({ iceServers: servers.length ? servers : stunOnly, turn: servers.some((s) => s.username) });
}

function json(value) {
  return new Response(JSON.stringify(value), { headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}

export class Room extends DurableObject {
  async fetch(request) {
    const role = new URL(request.url).searchParams.get("role");
    if (role !== "sender" && role !== "viewer") return new Response("Bad role", { status: 400 });
    const [client, server] = Object.values(new WebSocketPair());
    // One device per role: a reconnecting phone replaces its stale connection.
    for (const old of this.ctx.getWebSockets(role)) {
      try { old.close(4000, "replaced"); } catch {}
    }
    this.ctx.acceptWebSocket(server, [role]);
    if (role === "viewer") server.send(this.presence());
    else this.announce();
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket, message) {
    if (typeof message !== "string" || message.length > MAX_FRAME) return;
    if (message === "ping") { socket.send("pong"); return; }
    const role = this.ctx.getTags(socket)[0];
    for (const peer of this.open(role === "sender" ? "viewer" : "sender")) {
      try { peer.send(message); } catch {}
    }
  }

  async webSocketClose(socket) { this.closed(socket); }
  async webSocketError(socket) { this.closed(socket); }

  closed(socket) {
    try { socket.close(1000, "closed"); } catch {}
    if (this.ctx.getTags(socket)[0] === "sender") this.announce(socket);
  }

  open(role, excluding) {
    return this.ctx.getWebSockets(role).filter((s) => s !== excluding && s.readyState === WebSocket.OPEN);
  }

  presence(excluding) {
    return JSON.stringify({ relay: "presence", sender: this.open("sender", excluding).length > 0 });
  }

  announce(excluding) {
    const frame = this.presence(excluding);
    for (const viewer of this.open("viewer")) {
      try { viewer.send(frame); } catch {}
    }
  }
}
