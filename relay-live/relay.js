// The Workbench relay: lets a phone reach a Mac that has no address it can
// connect to, without Tailscale and without accounts.
//
// A Mac opens a room and keeps one WebSocket to it (the host). A paired
// device connects to the same room (a guest). The relay passes frames
// between them and nothing else. Everything a Mac and its devices say is
// sealed before it gets here, with keys the relay never sees, so the relay
// forwards bytes it can't read. Nothing is stored and nothing is logged.
//
// Rooms need no sign-up. A Mac makes a random key and the room's id is that
// key's SHA-256, so only the Mac can host its room and the relay keeps no
// list of rooms: it checks the key against the id each time.
//
//   GET /health                       {"ok":true,"rooms":n,"guests":n}
//   WS  /v1/rooms/<id>/host           Authorization: Bearer <key>
//   WS  /v1/rooms/<id>/guest
//
// Between the relay and a host:
//   text   {"t":"open","c":7}        a guest joined, as connection 7
//   text   {"t":"close","c":7}       that guest left (either side may send)
//   binary 4 bytes of connection id, then that guest's frame
// A guest sends and gets plain binary frames. Each frame is at most
// `maxFrame` bytes; the apps split anything longer.
//
// A refused or ended socket is closed with one of the codes below, so the
// apps can tell "the Mac is asleep" from "this room is over its limit".

import { createServer } from "node:http";
import { createHash, timingSafeEqual } from "node:crypto";
import { WebSocketServer } from "ws";

export const CLOSE = {
  badRequest: 4400,
  badKey: 4401,
  roomFull: 4403,
  hostOffline: 4404,
  silent: 4408,
  replaced: 4409,
  hostGone: 4410,
  tooBig: 4413,
  overLimit: 4429,
  slow: 4508,
};

export const DEFAULT_LIMITS = {
  // The largest frame a guest may send. A host's frames carry 4 more bytes.
  maxFrame: 256 * 1024,
  maxGuests: 8,
  // Sealed bytes forwarded for one room, both ways, per UTC day.
  roomBytesPerDay: 2 * 1024 * 1024 * 1024,
  // A Mac reconnects whenever its network changes, so this is generous.
  hostsPerAddressPerHour: 240,
  guestsPerAddressPerMinute: 60,
  maxRooms: 20000,
  // A guest that says nothing is not a Workbench app.
  firstFrameMs: 10000,
  pingMs: 30000,
  // A socket that isn't reading has this much queued before it's dropped.
  maxBuffered: 8 * 1024 * 1024,
};

/// Limits from the environment, by the same names in capitals with RELAY_
/// in front: RELAY_MAX_GUESTS=4, RELAY_ROOM_BYTES_PER_DAY=500000000.
export function limitsFromEnv(env) {
  const limits = { ...DEFAULT_LIMITS };
  for (const key of Object.keys(limits)) {
    const name = "RELAY_" + key.replace(/[A-Z]/g, (letter) => "_" + letter).toUpperCase();
    const value = Number(env[name]);
    if (env[name] !== undefined && Number.isFinite(value) && value > 0) limits[key] = value;
  }
  return limits;
}

const ROOM_PATH = /^\/v1\/rooms\/([0-9a-f]{64})\/(host|guest)$/;
const KEY = /^[0-9a-f]{64}$/;

export function roomID(key) {
  return createHash("sha256").update(Buffer.from(key, "hex")).digest("hex");
}

function ownsRoom(key, id) {
  if (!KEY.test(key)) return false;
  return timingSafeEqual(Buffer.from(roomID(key), "hex"), Buffer.from(id, "hex"));
}

/// So many events per window for each caller, counted in memory.
function counter(windowMs, now) {
  const recent = new Map();
  let lastSweep = now();
  return function over(caller, perWindow) {
    const time = now();
    if (time - lastSweep > windowMs) {
      for (const [key, times] of recent) {
        if (time - times[times.length - 1] >= windowMs) recent.delete(key);
      }
      lastSweep = time;
    }
    const times = (recent.get(caller) ?? []).filter((at) => time - at < windowMs);
    times.push(time);
    recent.set(caller, times);
    return times.length > perWindow;
  };
}

function callerOf(request) {
  const forwarded = String(request.headers["x-forwarded-for"] ?? "").split(",")[0].trim();
  return forwarded || request.socket.remoteAddress || "unknown";
}

/// Starts a relay. `now` is for tests. Resolves once it's listening.
export async function startRelay({ port = 0, limits: given = {}, now = Date.now } = {}) {
  const limits = { ...DEFAULT_LIMITS, ...given };
  // id -> { host, guests: Map(connection id -> socket), next }
  const rooms = new Map();
  // id -> { day, bytes }, kept after a room closes so a reconnect can't
  // reset its count.
  const used = new Map();
  const hostJoins = counter(60 * 60 * 1000, now);
  const guestJoins = counter(60 * 1000, now);

  const day = () => Math.floor(now() / 86_400_000);

  function spend(id, bytes) {
    const today = day();
    let entry = used.get(id);
    if (!entry || entry.day !== today) {
      entry = { day: today, bytes: 0 };
      used.set(id, entry);
    }
    entry.bytes += bytes;
    return entry.bytes <= limits.roomBytesPerDay;
  }

  function isSpent(id) {
    const entry = used.get(id);
    return entry !== undefined && entry.day === day() && entry.bytes > limits.roomBytesPerDay;
  }

  function closeRoom(id, code, reason) {
    const room = rooms.get(id);
    if (!room) return;
    rooms.delete(id);
    for (const guest of room.guests.values()) guest.close(code, reason);
    room.guests.clear();
  }

  /// Sends, unless the other end has stopped reading.
  function forward(socket, data, binary) {
    if (socket.readyState !== socket.OPEN) return;
    if (socket.bufferedAmount > limits.maxBuffered) {
      socket.close(CLOSE.slow, "not reading");
      return;
    }
    socket.send(data, { binary });
  }

  function acceptHost(socket, id) {
    const old = rooms.get(id);
    if (old) {
      // The Mac reconnected before its old socket was noticed gone.
      old.host.replaced = true;
      old.host.close(CLOSE.replaced, "replaced");
      closeRoom(id, CLOSE.hostGone, "host reconnected");
    }
    if (rooms.size >= limits.maxRooms) return socket.close(CLOSE.overLimit, "relay full");
    const room = { host: socket, guests: new Map(), next: 1 };
    rooms.set(id, room);

    socket.on("message", (data, isBinary) => {
      if (!isBinary) {
        let message;
        try {
          message = JSON.parse(data.toString());
        } catch {
          return socket.close(CLOSE.badRequest, "bad message");
        }
        if (message?.t === "close") room.guests.get(message.c)?.close(CLOSE.hostGone, "closed by host");
        return;
      }
      if (data.length < 4) return socket.close(CLOSE.badRequest, "bad frame");
      if (data.length > limits.maxFrame + 4) return socket.close(CLOSE.tooBig, "frame too big");
      const guest = room.guests.get(data.readUInt32BE(0));
      // The guest may have just left. Its close is already on the way.
      if (!guest) return;
      if (!spend(id, data.length - 4)) return overLimit(id);
      forward(guest, data.subarray(4), true);
    });
    socket.on("close", () => {
      if (!socket.replaced && rooms.get(id) === room) closeRoom(id, CLOSE.hostGone, "host gone");
    });
  }

  function overLimit(id) {
    const room = rooms.get(id);
    closeRoom(id, CLOSE.overLimit, "over today's limit");
    room?.host.close(CLOSE.overLimit, "over today's limit");
  }

  function acceptGuest(socket, id) {
    const room = rooms.get(id);
    if (!room) return socket.close(CLOSE.hostOffline, "host offline");
    if (room.guests.size >= limits.maxGuests) return socket.close(CLOSE.roomFull, "room full");
    const connection = room.next;
    room.next = room.next >= 0xffffffff ? 1 : room.next + 1;
    room.guests.set(connection, socket);
    forward(room.host, JSON.stringify({ t: "open", c: connection }), false);

    const silent = setTimeout(() => socket.close(CLOSE.silent, "said nothing"), limits.firstFrameMs);
    const prefix = Buffer.alloc(4);
    prefix.writeUInt32BE(connection);

    socket.on("message", (data, isBinary) => {
      clearTimeout(silent);
      if (!isBinary) return socket.close(CLOSE.badRequest, "binary only");
      if (data.length > limits.maxFrame) return socket.close(CLOSE.tooBig, "frame too big");
      if (!spend(id, data.length)) return overLimit(id);
      forward(room.host, Buffer.concat([prefix, data]), true);
    });
    socket.on("close", () => {
      clearTimeout(silent);
      if (room.guests.get(connection) !== socket) return;
      room.guests.delete(connection);
      forward(room.host, JSON.stringify({ t: "close", c: connection }), false);
    });
  }

  const server = createServer((request, response) => {
    if (request.method === "GET" && request.url === "/health") {
      let guests = 0;
      for (const room of rooms.values()) guests += room.guests.size;
      response.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
      return response.end(JSON.stringify({ ok: true, rooms: rooms.size, guests }));
    }
    response.writeHead(404, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: false }));
  });

  // 4 bytes over a host's largest frame, and ws itself refuses the rest.
  const sockets = new WebSocketServer({ noServer: true, maxPayload: limits.maxFrame + 4 });

  server.on("upgrade", (request, socket, head) => {
    const match = ROOM_PATH.exec(new URL(request.url, "http://relay").pathname);
    if (!match) {
      socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      return socket.destroy();
    }
    const [, id, role] = match;
    sockets.handleUpgrade(request, socket, head, (ws) => {
      // Refusals happen after the upgrade, so the app gets a close code it
      // can read. A failed HTTP upgrade tells it nothing.
      ws.on("error", () => ws.terminate());
      ws.alive = true;
      ws.on("pong", () => (ws.alive = true));
      const caller = callerOf(request);
      if (isSpent(id)) return ws.close(CLOSE.overLimit, "over today's limit");
      if (role === "host") {
        const key = String(request.headers.authorization ?? "").replace(/^Bearer /, "");
        if (!ownsRoom(key, id)) return ws.close(CLOSE.badKey, "wrong key");
        if (hostJoins(caller, limits.hostsPerAddressPerHour)) return ws.close(CLOSE.overLimit, "too many rooms");
        acceptHost(ws, id);
      } else {
        if (guestJoins(caller, limits.guestsPerAddressPerMinute)) return ws.close(CLOSE.overLimit, "too many tries");
        acceptGuest(ws, id);
      }
    });
  });

  // Finds sockets whose other end vanished without closing, and keeps the
  // rest open through proxies that drop quiet connections.
  const pings = setInterval(() => {
    for (const ws of sockets.clients) {
      if (!ws.alive) {
        ws.terminate();
        continue;
      }
      ws.alive = false;
      ws.ping();
    }
    const today = day();
    for (const [id, entry] of used) if (entry.day !== today) used.delete(id);
  }, limits.pingMs);
  pings.unref();

  await new Promise((resolve) => server.listen(port, resolve));

  return {
    port: server.address().port,
    rooms,
    async close() {
      clearInterval(pings);
      for (const ws of sockets.clients) ws.close(1001, "relay restarting");
      // Anyone who doesn't answer the close is cut off, so this can't hang.
      const cut = setTimeout(() => {
        for (const ws of sockets.clients) ws.terminate();
      }, 500);
      await new Promise((resolve) => server.close(resolve));
      clearTimeout(cut);
    },
  };
}
