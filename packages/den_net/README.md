# den_net

Den's networking layer: encrypted device sessions, the sync protocol, pairing (QR invites,
spoken codes, matching words), the relay client and encrypted backups. It implements the
"Network" section of `ARCHITECTURE.md`.

- `package:den_net/den_net.dart` is pure Dart with no `dart:io`, so the app, browsers, the hub
  and tests share it.
- `package:den_net/io.dart` adds what needs `dart:io`: mDNS discovery of `_den._tcp` hubs and a
  shelf WebSocket handler for serving sync.
- `package:den_net/relay_protocol.dart` is the wire protocol shared with `den_relay`.

## What the hub and the app call

| Need | API |
| --- | --- |
| Run sync for a `Den` | `SyncNode(den)`; `node.close()` |
| Hub `/ws`, tunnel streams, hub mode on devices | `node.serve(channel)`; in shelf: `syncWebSocketHandler(node)` (io.dart); standalone: `serveSync(node, port: 47733)` |
| Device to hub, with reconnects | `SyncClient(node: node, endpoints: [ws://hub:47733/ws, relayConnectUri(relay, hubId)])`, `start()`, `statusChanges` (`connecting`, `syncing`, `live`, `offline` with `lastError`), `whenLive()`, `retryNow()`, `stop()` |
| One connection by hand | `node.connect(channel, expectDevice: hubId)` returns a `SyncPeer` (`live`, `closed`, `phase`, `closeReason`) |
| Invite with a QR code | `node.createInvite(hubs: [...], relay: ...)` then `invite.toUrl()`; inviting phone with no hub: `node.hostRendezvous(relay, await invite.rendezvousSlot())` |
| Invite a joiner the hub admits (browser linking) | phone: `node.createHubInvite(hubId, hubs: [...])`, `InviteGrant.sign(invite, keys: den.keys, context: ...)`; hub: `node.acceptInviteGrant(grant, context: ...)` (null when accepted, else the reason) |
| Invite with a spoken code | `node.createSpokenCode()` (`code.text`, `code.expires`); with no hub: `node.hostRendezvous(relay, await codeRendezvousSlot(code.text))` |
| Show and approve joiners | `node.pendingJoinsChanges` / `node.pendingJoins` (`PendingJoin`: `name`, `kind`, `matchingWords`, `via`, `requestedMember`, `requestedMode`); `node.approve(join, member: ..., mode: ...)` (calls `den.approveDevice`); `node.decline(join)` |
| Join with a scanned QR code | `final invite = await Invite.parse(url)`; `final channel = await openInviteChannel(invite)`; `final attempt = await node.joinWithInvite(channel, invite, deviceName: ..., kind: ...)`; `attempt.matchingWords`, `attempt.stages`, `await attempt.completed` |
| Join with a spoken code | `channel = await rendezvous(relay, await codeRendezvousSlot(code), host: false)` (or a hub found on the LAN); `node.joinWithCode(channel, code, ...)` |
| Hub reachable through a relay | `RelayTunnel(relay: ..., keys: den.keys, onClient: (c) => node.serve(c))..start()`; `status`, `statusChanges`, `whenOnline()` |
| No hub online | `MailboxSync(node: node, relay: RelayMailbox(relay), state: store)`: `syncOnce()` (returns `MailboxRound`: received, posted, skipped, keysStored, keysDelivered), `start(interval)`, `stop()`; space keys through the relay: `deliverKeys(deviceId)`, `receiveKeys()` |
| Space keys changed outside a den write | `node.keysChanged()` (the key in use is also checked a few seconds after every change and every 5 seconds) |
| Space keys themselves (den_core) | `den.currentSpaceKey(space)` (a `SpaceKey`: `epoch`, `key`, `hash`, `by`, `revoked`, `sig`), `den.spaceKeysAt(space, epoch)`, `den.addSpaceKey(key)` (`SpaceKeyOutcome`), `den.spaceKeyToShare(space)`, `den.staleSpaceKeys`, `den.makesSpaceKeys` |
| Backups | `encryptBackup(bytes, passphrase)`, `decryptBackup(bytes, passphrase)` (throws `BackupException`) |
| LAN discovery | `discoverHubs()` (io.dart) returns `DiscoveredHub` (`syncUri`, `deviceId`, `familyId`) |
| Lower level | `Session.connect` / `Session.accept`, `sealToDevice` / `openSealed`, `sealSpaceKey` / `openSpaceKey`, `sealChanges` / `openChanges`, `mailboxId`, `matchingWords`, `normalizeCode`, `CodeBook`, `InviteBook` |

## Sessions

Every connection, direct or through a relay, starts with this handshake inside the channel (any
`StreamChannel` of strings, of bytes, or a WebSocket mixing both):

1. Client: `{"t":"hello","v":1,"family","device","pubkey","eph"}`; `eph` is a fresh X25519 key.
   `family` is null only for a spoken-code joiner.
2. Server: `{"t":"hello","v":1,"family","device","pubkey","eph","sig"}`.
3. Client: `{"t":"auth","sig"}`.

`device` must equal base32 of the first 10 bytes of SHA-256 of `pubkey`. The transcript hash is
SHA-256 of `"den/session/v1" 0x00 | len(c) | c | len(s) | s`, where `c` and `s` are the canonical
JSON of the client hello and of the server hello without `sig`, and lengths are u32 big-endian.
The server signs `"den/session/v1/server" | hash`, the client `"den/session/v1/client" | hash`;
the labels keep one side's signature from ever passing as the other's. Keys: HKDF-SHA256 over
the X25519 shared secret (all-zero results refused), salt = transcript hash, info
`"den/session/v1 c2s"` and `"den/session/v1 s2c"`.

Frames: 8-byte big-endian counter, AES-256-GCM ciphertext, 16-byte tag; nonce = direction byte
(1 client to server, 2 server to client), three zero bytes, the counter. Counters start at 1 and
must go up by exactly one, so a replayed, reordered, dropped or tampered frame closes the
session. Text channels carry frames as base64url. Messages are JSON objects of at most 1 MiB.

Clients can pin the server (`expectDevice`, `expectPubkey`): QR joiners pin the inviter from
the code, relay clients pin the hub id in `/connect/<hubId>`. The matching words are three words
from SHA-256 of `"den/sas/v1" | transcript hash` (11 bits each); a relay running its own two
sessions produces two transcripts, so the screens disagree.

## Sync messages

| Message | Meaning |
| --- | --- |
| `have {vv: {space: {author: [max, count, digest]}}, keys: {space: [epoch, hash]}}` | What I hold per space I'm entitled to and the peer may read: highest counter, how many, and the sum mod 2^32 of MurmurHash3's finalizer over the counters; and the key I use per space (its epoch and hash) |
| `changes {list, done}` | The answer to `have`: what the peer lacks, in HLC order, in batches of up to 256 KiB, then any `keys`, then an empty `changes` with `done: true` |
| `push {list}` | Changes as they're written or arrive from elsewhere |
| `keys {space, epoch, key, by, revoked, sig}` | The key I use for a space the peer may hold, with its maker's statement, unless the peer has said it holds a newer epoch or that very key |
| `probe {vv: {space: {author: bound}}}` / `probe_ok {vv: {space: {author: [bound, count, digest]}}}` | When the peer's `have` is ahead of mine for an author, I ask for its summary up to my max; a mismatch means it has holes there, so I push that author's history |

A side sends only spaces `den.spacesForDevice(peer)` allows and accepts from a known peer only
changes in spaces that peer may hold. Version vectors from `den.versionVector` are not on the
wire: counters are per device across every space, so a device that never receives `p` can't
have a contiguous vector; the per-space summaries above don't need one, and they detect holes
from out-of-order delivery. Changes new to this replica are forwarded to every other live peer
once, so a hub relays between its clients and a chain of devices converges.

### Space-key epochs

When a parent's device revokes a device, den_core rotates the key of every space it held (one
epoch past every epoch held) and keeps the older epochs. The rotating device then sends each
connected peer its changes first (the revocation among them) and the new keys after, so a peer
has always ingested the revocation before it holds, and passes on, the keys it caused. Keys go
only to devices `den.spacesForDevice` allows at that moment, which leaves out a revoked device,
and its session is closed. A device that was away gets the key in use from the next `have`
exchange.

Each key carries its maker's statement (ARCHITECTURE.md, "Genesis and trust"): the maker's
device signs the family, space, epoch, the key's hash and the devices revoked by then. A receiver
hands the key to `den.addSpaceKey`, which keeps it only when the statement verifies and the maker
is a parent's device or a hub; it ignores keys for spaces the sender may not hold, and passes
on whatever changed the key it uses. A key for an epoch it already holds, made by another
parent who rotated at the same time, is kept beside the first; every replica uses the one with
the lowest hash, and reads both mailboxes. Because `have` names the key in use by epoch and hash,
two devices that hold different keys for one epoch each send theirs and end up using the same
one. When the key in use doesn't list a revoked device that another key held for the space
does, it may have reached that device, so a parent's device or hub rotates once more; that key
lists both revocations, which settles it.

## Pairing

- `pair {kind: "qr", proof}`: proof = base64url HMAC-SHA256(invite secret, raw Ed25519 key of
  the joiner). Invites are single-use.
- `pair {kind: "code", proof}`: proof = HMAC-SHA256(key = the normalized code, `"den/pair/v1/joiner"
  0x00 | transcript hash | joiner key`). The inviting side answers with its own proof under the
  label `"den/pair/v1/host"`, so a joiner never pairs with a device that doesn't know the code.
  Every wrong proof counts against every live code (a guess doesn't say which code it aimed at);
  5 burn them. Codes last 10 minutes.
- `pair_ok {family, founder, proof?}` / `pair_fail {reason}`.
- `join {changes}`: the joiner's own unapproved `device` record from `den.requestJoin`; refused
  if any change is not that record, sets `approved` true, `approvedBy`, `revoked`, or another
  key. A device whose pending record already exists can resume with `join` alone.
- `join_pending`, `join_rejected {reason}`, `approved`, and `unapproved` (to a known-family
  client the server doesn't consider approved).

Until a parent approves the device (observed through `Den.onChange`), the server sends only
those messages; any sync message from the joiner closes the session. Then it sends `approved`,
`keys` for each space the device may hold, and `have`.

## Relay client

- Tunnel (hub side): `wss://relay/tunnel/<hubId>`; answer `{"t":"challenge","nonce"}` with
  `{"t":"auth","pubkey","sig"}` signing `"den/relay-tunnel/v1|<hubId>|<nonce>"`; after
  `{"t":"ready"}` client streams arrive multiplexed (see `den_relay`'s README).
- Rendezvous: `wss://relay/rendezvous/<slot>?role=host|guest`; slots are hex SHA-256 of
  `"den/rendezvous/v1/qr|" | secret` or `"den/rendezvous/v1/code|<normalized code>"`.
- Mailbox: id = hex HMAC-SHA256(space key, `"mailbox:<epoch>"`); blob = `0x01 | nonce (24) |
  XChaCha20-Poly1305(space key, {"v":1,"changes":[...]}, aad "den/mailbox/v1|<space>|<epoch>")`.
  Dedupe is by change id; only changes from the last 30 days are posted. Devices post under the
  key in use and read every key they hold for its epoch, and each older epoch they hold a key for
  until 30 days after they first saw a newer one (the relay's blob lifetime), so changes posted
  by a device that hadn't heard of a rotation, or used another parent's key for the same epoch,
  still arrive. A new epoch's mailbox starts out knowing what the previous one holds, so a switch
  doesn't repost a month of changes. Each round first takes keys from the device's inbox; on a
  device that makes keys it then leaves the key in use, when it made it (a rotation), in the
  inbox of each other device that may hold the space. When what a round reads changes the key in
  use (a revocation it hadn't heard of makes it rotate again), it posts under the new key from
  the next round on, never under one it just left. Key pushes to live sessions wait until the
  round has ingested what it read.
- Sealed to a device: `{v, from, to, eph, nonce, ct, sig}`; X25519 from a fresh key to the
  device's `xpub`, HKDF-SHA256 (salt eph | xpub, info `"den/seal/v1|from|to"`),
  XChaCha20-Poly1305, Ed25519 signature by the sender over `"den/seal/v1" 0x00 | canonical
  JSON [v, from, to, eph, nonce, ct]`. Device inboxes are hex SHA-256 of `"den/inbox/v1|<xpub>"`;
  the payload is a `keys {space, epoch, key, by, revoked, sig}` message from an approved device,
  and the key in it is kept only when its maker's statement verifies.

## Backups

`"DENB" | version 1 | KDF 1 (Argon2id) | memory KiB u32 | iterations u32 | parallelism u8 |
salt (16) | nonce (24) | XChaCha20-Poly1305 ciphertext and tag`, the header authenticated as
associated data. Defaults: 19 MiB, t=2, p=1. Headers asking for more than 1 GiB, 64 passes or
16 lanes are refused.

## Third-party material

The spoken-code word list is the BIP-39 English list; see `LICENSE-NOTICE`.
