import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { once } from "node:events";
import WebSocket from "ws";
import { startRelay, roomID, limitsFromEnv, CLOSE, DEFAULT_LIMITS } from "../relay.js";

const newKey = () => randomBytes(32).toString("hex");

async function relayWith(limits = {}, extra = {}) {
  const relay = await startRelay({ limits, ...extra });
  return { relay, base: `ws://127.0.0.1:${relay.port}` };
}

/// A socket that remembers what it got, so a test can wait for the next
/// thing without missing one that arrived early.
function open(url, options) {
  const socket = new WebSocket(url, options);
  socket.got = [];
  socket.waiting = [];
  const push = (item) => {
    const waiter = socket.waiting.shift();
    if (waiter) waiter(item);
    else socket.got.push(item);
  };
  socket.on("message", (data, isBinary) => push(isBinary ? { data } : { text: JSON.parse(data.toString()) }));
  socket.on("close", (code) => push({ closed: code }));
  socket.on("error", () => {});
  socket.next = () =>
    socket.got.length ? Promise.resolve(socket.got.shift()) : new Promise((resolve) => socket.waiting.push(resolve));
  return socket;
}

async function host(base, key = newKey()) {
  const socket = open(`${base}/v1/rooms/${roomID(key)}/host`, { headers: { authorization: `Bearer ${key}` } });
  await once(socket, "open");
  return { socket, key, id: roomID(key) };
}

async function guest(base, id) {
  const socket = open(`${base}/v1/rooms/${id}/guest`);
  await once(socket, "open");
  return socket;
}

function toGuest(connection, payload) {
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(connection);
  return Buffer.concat([prefix, Buffer.from(payload)]);
}

test("frames pass both ways, tagged with the guest's connection", async () => {
  const { relay, base } = await relayWith();
  const mac = await host(base);
  const phone = await guest(base, mac.id);
  assert.deepEqual(await mac.socket.next(), { text: { t: "open", c: 1 } });

  phone.send(Buffer.from("hello mac"));
  const frame = (await mac.socket.next()).data;
  assert.equal(frame.readUInt32BE(0), 1);
  assert.equal(frame.subarray(4).toString(), "hello mac");

  mac.socket.send(toGuest(1, "hello phone"));
  assert.equal((await phone.next()).data.toString(), "hello phone");
  await relay.close();
});

test("two guests stay apart", async () => {
  const { relay, base } = await relayWith();
  const mac = await host(base);
  const phone = await guest(base, mac.id);
  const tablet = await guest(base, mac.id);
  assert.deepEqual(await mac.socket.next(), { text: { t: "open", c: 1 } });
  assert.deepEqual(await mac.socket.next(), { text: { t: "open", c: 2 } });

  mac.socket.send(toGuest(2, "for the tablet"));
  assert.equal((await tablet.next()).data.toString(), "for the tablet");
  tablet.send(Buffer.from("from the tablet"));
  assert.equal((await mac.socket.next()).data.readUInt32BE(0), 2);
  assert.equal(phone.got.length, 0);
  await relay.close();
});

test("only the key's owner can host a room", async () => {
  const { relay, base } = await relayWith();
  const id = roomID(newKey());
  const wrong = open(`${base}/v1/rooms/${id}/host`, { headers: { authorization: `Bearer ${newKey()}` } });
  assert.deepEqual(await wrong.next(), { closed: CLOSE.badKey });
  const none = open(`${base}/v1/rooms/${id}/host`);
  assert.deepEqual(await none.next(), { closed: CLOSE.badKey });
  assert.equal(relay.rooms.size, 0);
  await relay.close();
});

test("a guest is told when the Mac isn't there", async () => {
  const { relay, base } = await relayWith();
  const phone = open(`${base}/v1/rooms/${roomID(newKey())}/guest`);
  assert.deepEqual(await phone.next(), { closed: CLOSE.hostOffline });
  await relay.close();
});

test("the host hears a guest leave, and guests are closed when the host goes", async () => {
  const { relay, base } = await relayWith();
  const mac = await host(base);
  const phone = await guest(base, mac.id);
  const tablet = await guest(base, mac.id);
  await mac.socket.next();
  await mac.socket.next();

  phone.close();
  assert.deepEqual(await mac.socket.next(), { text: { t: "close", c: 1 } });

  mac.socket.close();
  assert.deepEqual(await tablet.next(), { closed: CLOSE.hostGone });
  assert.equal(relay.rooms.size, 0);
  await relay.close();
});

test("the host can close one guest", async () => {
  const { relay, base } = await relayWith();
  const mac = await host(base);
  const phone = await guest(base, mac.id);
  await mac.socket.next();
  mac.socket.send(JSON.stringify({ t: "close", c: 1 }));
  assert.deepEqual(await phone.next(), { closed: CLOSE.hostGone });
  assert.deepEqual(await mac.socket.next(), { text: { t: "close", c: 1 } });
  await relay.close();
});

test("a Mac that reconnects takes its room back", async () => {
  const { relay, base } = await relayWith();
  const first = await host(base);
  const phone = await guest(base, first.id);
  await first.socket.next();

  const second = await host(base, first.key);
  assert.deepEqual(await first.socket.next(), { closed: CLOSE.replaced });
  assert.deepEqual(await phone.next(), { closed: CLOSE.hostGone });

  const again = await guest(base, first.id);
  assert.deepEqual(await second.socket.next(), { text: { t: "open", c: 1 } });
  again.send(Buffer.from("still here"));
  assert.equal((await second.socket.next()).data.subarray(4).toString(), "still here");
  await relay.close();
});

test("a frame over the size limit ends the connection", async () => {
  const { relay, base } = await relayWith({ maxFrame: 1024 });
  const mac = await host(base);
  const phone = await guest(base, mac.id);
  await mac.socket.next();
  phone.send(Buffer.alloc(1024));
  assert.equal((await mac.socket.next()).data.length, 1028);
  phone.send(Buffer.alloc(1025));
  const closed = await phone.next();
  assert.ok(closed.closed === CLOSE.tooBig || closed.closed === 1009 || closed.closed === 1006, `closed ${closed.closed}`);
  await relay.close();
});

test("a room holds only so many guests", async () => {
  const { relay, base } = await relayWith({ maxGuests: 1 });
  const mac = await host(base);
  await guest(base, mac.id);
  const second = open(`${base}/v1/rooms/${mac.id}/guest`);
  assert.deepEqual(await second.next(), { closed: CLOSE.roomFull });
  await relay.close();
});

test("a guest must speak binary, and must speak soon", async () => {
  const { relay, base } = await relayWith({ firstFrameMs: 60 });
  const mac = await host(base);
  const texter = await guest(base, mac.id);
  texter.send("plain text");
  assert.deepEqual(await texter.next(), { closed: CLOSE.badRequest });

  const quiet = await guest(base, mac.id);
  assert.deepEqual(await quiet.next(), { closed: CLOSE.silent });
  await relay.close();
});

test("a room over its daily allowance closes, and stays closed until tomorrow", async () => {
  let time = Date.UTC(2026, 10, 26, 12);
  const { relay, base } = await relayWith({ roomBytesPerDay: 100 }, { now: () => time });
  const mac = await host(base);
  const phone = await guest(base, mac.id);
  await mac.socket.next();
  phone.send(Buffer.alloc(80));
  assert.equal((await mac.socket.next()).data.length, 84);
  phone.send(Buffer.alloc(80));
  assert.deepEqual(await phone.next(), { closed: CLOSE.overLimit });
  assert.deepEqual(await mac.socket.next(), { closed: CLOSE.overLimit });

  const back = open(`${base}/v1/rooms/${mac.id}/host`, { headers: { authorization: `Bearer ${mac.key}` } });
  assert.deepEqual(await back.next(), { closed: CLOSE.overLimit });

  time += 86_400_000;
  const tomorrow = await host(base, mac.key);
  assert.equal(tomorrow.socket.readyState, WebSocket.OPEN);
  await relay.close();
});

test("one address can't open rooms or try guests without end", async () => {
  const { relay, base } = await relayWith({ hostsPerAddressPerHour: 2, guestsPerAddressPerMinute: 2 });
  await host(base);
  const mac = await host(base);
  const third = newKey();
  const refused = open(`${base}/v1/rooms/${roomID(third)}/host`, { headers: { authorization: `Bearer ${third}` } });
  assert.deepEqual(await refused.next(), { closed: CLOSE.overLimit });

  await guest(base, mac.id);
  await guest(base, mac.id);
  const tooMany = open(`${base}/v1/rooms/${mac.id}/guest`);
  assert.deepEqual(await tooMany.next(), { closed: CLOSE.overLimit });
  await relay.close();
});

test("health answers with counts and nothing else is served", async () => {
  const { relay, base } = await relayWith();
  const mac = await host(base);
  await guest(base, mac.id);
  await mac.socket.next();
  const http = base.replace("ws:", "http:");
  const health = await fetch(`${http}/health`);
  assert.deepEqual(await health.json(), { ok: true, rooms: 1, guests: 1 });
  assert.equal((await fetch(`${http}/v1/rooms/${mac.id}/guest`)).status, 404);

  const stray = new WebSocket(`${base}/anything`);
  const refused = await new Promise((resolve) => {
    stray.on("open", () => resolve(false));
    stray.on("error", () => resolve(true));
  });
  assert.ok(refused);
  await relay.close();
});

test("limits can be set from the environment", () => {
  const limits = limitsFromEnv({ RELAY_MAX_GUESTS: "3", RELAY_ROOM_BYTES_PER_DAY: "500", RELAY_PING_MS: "nonsense" });
  assert.equal(limits.maxGuests, 3);
  assert.equal(limits.roomBytesPerDay, 500);
  assert.equal(limits.pingMs, DEFAULT_LIMITS.pingMs);
});
