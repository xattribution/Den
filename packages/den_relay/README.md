# den_relay

Rendezvous, tunnel and mailbox for Den devices that can't reach each other or their hub
directly. It keeps no accounts, sees only ciphertext and signatures, and logs nothing about
requests: no content, mailbox ids, slots, hub ids or addresses. It prints one line at start and
the type of any internal error.

```
dart run bin/den_relay.dart --port 47734 --data-dir data [--trust-proxy]
dart compile exe bin/den_relay.dart -o den_relay
den_relay --healthcheck        # exit 0 if the relay on --port answers /health
```

`--port` and `--data-dir` default to `DEN_RELAY_PORT` and `DEN_RELAY_DATA`. Serve it behind a
TLS reverse proxy; `--trust-proxy` makes rate limits use the last `X-Forwarded-For` entry (the
address the proxy saw) and must not be set when clients can reach the relay directly. Docker:
`deploy/relay`.

## Endpoints

| Route | What |
| --- | --- |
| `GET /health` | `{ok, version}`; never rate limited |
| `GET /tunnel/<hubId>` (WebSocket) | A hub's tunnel |
| `GET /connect/<hubId>` (WebSocket) | A device reaching that hub; 404 before the upgrade if the hub isn't connected |
| `GET /rendezvous/<slot>?role=host\|guest` (WebSocket) | One-shot pairing meeting point |
| `POST /mailbox/<id>` | Append a blob (1 byte to 1 MiB): `{cursor}`; 413 too large, 507 a cap was reached |
| `GET /mailbox/<id>?after=<cursor>&limit=<n>` | `{items: [{c, b}], next, more}`; `b` is base64url |

Hub ids are 16 base32 characters; mailbox ids and slots are 64 hex characters.

### Tunnel

1. The relay sends `{"t":"challenge","nonce":<32 random bytes, base64url>}`.
2. Within 10 seconds the hub answers `{"t":"auth","pubkey","sig"}`. The relay checks that
   `hubId` is base32 of the first 10 bytes of SHA-256 of `pubkey` and that `sig` is the Ed25519
   signature of `"den/relay-tunnel/v1|<hubId>|<nonce>"`; otherwise it closes with 4401.
3. The relay sends `{"t":"ready"}`. A newer authenticated tunnel for the same hub replaces the
   old one (closed with 4409).

Client streams are **multiplexed over the hub's one socket** rather than asking the hub to open
a socket per client: the hub needs a single outbound connection, which works through NAT and
keeps one place to authenticate. Every later message on the tunnel is binary:
`op (1 byte) | stream id (u32 big-endian) | payload`, with ops `1` open (relay to hub, empty
payload), `2` text and `3` binary (a client WebSocket message, unchanged, either direction), and
`4` close (either direction). The relay never tells the hub a client's address. The session
handshake runs end to end inside each stream, so the relay can't read or alter what it pipes.

### Rendezvous

A host waits up to 15 minutes. A guest is refused (404 before the upgrade, or close 4404) unless
a host is waiting; when one is, both receive `{"t":"paired"}` and messages are forwarded
unchanged until either side closes. A slot serves one pairing; a second host gets 409.

### Mailboxes

Each mailbox is one append-only file, `<data-dir>/mailboxes/<id[0..2]>/<id>.box`, of records
`cursor (u64) | created ms (u64) | length (u32) | blob`; a torn final record is truncated on
start. Cursors are `max(previous + 1, now_ms * 1000)`, so they keep increasing even after a
mailbox expires completely. Blobs older than 30 days are hidden from reads and removed by an
hourly sweep that rewrites the file.

## Limits (defaults, in `RelayConfig`)

| Limit | Default |
| --- | --- |
| Requests per client address | burst 120, 20/s |
| Appends per mailbox | burst 120, 2/s |
| Reads per mailbox | burst 240, 4/s |
| Blob size / WebSocket message size | 1 MiB |
| Per mailbox | 10,000 blobs, 32 MiB |
| Mailboxes / total stored | 100,000 / 10 GiB |
| Read page | 200 blobs or 8 MiB |
| Tunnels / streams per tunnel | 10,000 / 64 |
| Waiting rendezvous hosts | 10,000 |

Over a rate limit the relay answers 429 with `Retry-After`.
