# Workbench live relay

Lets a phone, or another Mac, reach a Mac from anywhere without Tailscale
and without an account. The Mac and the device both connect out to this
service, and it passes sealed messages between them.

It is a separate service from `relay/` (notifications, feedback and the
sleep queue, on Vercel) because it holds connections open, which wants one
always-on process. It runs on Railway, or anywhere Node does.

## What it can and can't see

Everything a Mac and its devices say is sealed on the device, with keys
that come from the pairing code. The relay never has those keys.

- It sees: a random room id, the network addresses of the two ends while
  they're connected, and how much data moves and when.
- It can't see: project names, code, prompts, replies, or the pairing code.

Nothing is written to disk and nothing is logged. The only state is in
memory: which rooms are open, and how many bytes each has used today.

## How it works

A Mac makes a random 32-byte key. The room's id is that key's SHA-256, so
only that Mac can host the room, and the relay needs no list of rooms or
users: it checks the key against the id on each connection.

| | |
|---|---|
| `GET /health` | `{"ok":true,"rooms":n,"guests":n}` |
| `WS /v1/rooms/<id>/host` | The Mac. `Authorization: Bearer <key>`, both in lowercase hex |
| `WS /v1/rooms/<id>/guest` | A paired device |

A guest sends and receives plain binary frames. The host has one socket
for every guest, so its frames are tagged:

- text `{"t":"open","c":7}`: a guest joined, as connection 7
- text `{"t":"close","c":7}`: that guest left. The host may send it too, to
  close one
- binary: 4 bytes of connection id (big-endian), then the guest's frame

A room exists only while its Mac is connected. When the Mac goes, its
guests are closed.

## Close codes

| Code | Meaning | What the app should do |
|---|---|---|
| 4400 | Bad frame or message | Nothing: a bug |
| 4401 | Wrong key for this room | Nothing: a bug |
| 4403 | Room has its full count of guests | Say so |
| 4404 | The Mac isn't connected | Try again later, or queue |
| 4408 | A guest said nothing after joining | Nothing: a bug |
| 4409 | The Mac connected again elsewhere | Drop this socket |
| 4410 | The Mac went away, or closed this guest | Reconnect |
| 4413 | Frame over the size limit | Nothing: a bug (split it) |
| 4429 | Over a limit: today's data, or too many tries | Wait, and say so |
| 4508 | This end stopped reading | Reconnect |
| 1001 | The relay is restarting | Reconnect |

## Limits

Each has a default in `relay.js` and can be set from the environment, as
`RELAY_` plus the name in capitals.

| Setting | Default | |
|---|---|---|
| `RELAY_MAX_FRAME` | 262144 | Bytes in one frame |
| `RELAY_MAX_GUESTS` | 8 | Devices in one room at once |
| `RELAY_ROOM_BYTES_PER_DAY` | 2147483648 | Sealed bytes per room per UTC day, both ways |
| `RELAY_HOSTS_PER_ADDRESS_PER_HOUR` | 240 | Rooms opened from one address, reconnects included |
| `RELAY_GUESTS_PER_ADDRESS_PER_MINUTE` | 60 | Guest connections from one address |
| `RELAY_MAX_ROOMS` | 20000 | Rooms open at once |
| `RELAY_FIRST_FRAME_MS` | 10000 | How long a new guest may stay silent |
| `RELAY_PING_MS` | 30000 | How often each socket is pinged |
| `RELAY_MAX_BUFFERED` | 8388608 | Bytes queued for a socket that isn't reading |

The counts live in memory, so they reset when the service restarts. They
are a brake on abuse and runaway loops, not an exact meter.

## Run it

```sh
cd relay-live
npm install
npm test
PORT=8080 npm start
```

## Deploy on Railway

Ours runs as the `relay` service in the Railway project `workbench-relay`.
To deploy a change:

```sh
cd relay-live
railway up --service relay --ci
```

Setting one up from nothing:

```sh
cd relay-live
railway login                              # once
railway init --name workbench-relay        # a project
railway add --service relay                # an empty service in it
railway up --service relay --ci            # builds from package.json, runs `npm start`
railway domain --service relay             # a public address
```

Railway reads the start command from `package.json`. If the service is
deployed from the GitHub repo instead of `railway up`, set its root
directory to `relay-live`.

Keep it at **one replica**. A room lives in one process, so with two, a
Mac and its phone could land on different ones and never meet. More than
one replica needs a shared store between them, which this doesn't have.

A redeploy closes every connection with 1001. The Mac and its devices
reconnect on their own.

## Host your own

The same steps work on any host that keeps a Node process running and
passes WebSockets through. Point Workbench at it in Settings > iPhone.
