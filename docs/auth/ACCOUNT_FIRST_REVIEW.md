# Den auth review and account-first plan (for Claude to implement)

Status: design and review only. No code is changed by this document.
Base: `family-ready` at `7248c3c868225255d42cfd7131aa6c08a65c8e09`. Every `path:line` below was checked against that commit.
Source plan: `den-auth-concept/PLAN.md` v3.2 (kept outside the repo). Where this document and the code disagree, the code wins; report the mismatch.
Inferences are marked **[INF]**. Path shorthand: `core/` = `packages/den_core/lib/src/`, `hub/` = `packages/den_hub/lib/src/`.

---

## 1. Current auth review

### 1.1 Device keys and the signed log
What it does: every change is signed by a device key and checked by every replica in `core/validity.dart`. Sessions and transport live in `packages/den_net/lib/src/session.dart` (see `ARCHITECTURE.md`, "Sessions").

- Strength: integrity does not depend on the hub. A tampered or forged change is rejected on every device, offline too.
- Strength: the relay can carry end-to-end traffic because trust is in the log, not the server.
- Weakness: the device key *is* the identity. A person with no surviving device has no identity left except recovery words or the operator (`hub/recovery.dart:76-86`).
- Keep: this layer stays. Only *what makes a device trusted* changes (section 2).

### 1.2 `core/validity.dart`
Entry dispatch, `core/validity.dart:140-160`:
- `:142-145` a device change carrying `recovery` goes to `checkRecovery`.
- `:146-149` a device change carrying `invite` goes to `checkInviteJoin`.
- `:150-152` the founder device with no record goes to `_genesis`.
- `:153-158` a device writing its own record while not approved goes to `_join` (pending request).
- `:160` anything else from an unknown device: "This device isn't part of the family".

`_join`, `core/validity.dart:253-271`:
- `:259-261` a joining device can never set `approved`, `approvedBy`, or `revoked: false`.
- `:263-264` a new join record must say `approved: false`.
- `:266-270` while waiting, only `name, kind, xpub, revoked, revokedAfter, approved` may change.

`_device`, `core/validity.dart:479-515`:
- `:481` devices are never created by others; they join themselves.
- `:484` a hub acting for a connection (`_via`) can't touch device records.
- `:493-495` an approved device's `member` can't change ("Remove it and add it again").
- `:496-508` a device editing itself can't approve itself or change owner; only a parent may change `mode`.
- `:509-513` approval requires `manageFamily`, a parent actor, and the parent's own device.

`_connection`, `core/validity.dart:649-680` (approx.): only a parent on their own device creates/approves; the hub may create a pending OAuth connection (`:657-659`), revoke (`:669-670`), and set `tokenHash`/`expires` only on an active connection (`:674-676`).

Strengths:
- Self-approval is closed off in three separate places (`:259-261`, `:500-504`, and recovery/invite proofs being the only exceptions).
- Owner pinning (`:493-495`) prevents moving a device's held data to someone else.
- Connections can't escalate through the hub (`:484`).

Weaknesses:
- Four entry paths (genesis, join+approval, recovery proof, invite proof), each with separate rules and tests.
- Trust is a stored flag (`approved`, `approvedBy`), so a parent losing parent status does not automatically narrow what devices they approved can do [INF: verify by test; `access.dart:38-44` handles this for connections only].
- The pending state is attack surface: anyone with an invite's words can put up to 3 requests in front of a parent (`hub/invites.dart:64-66`).

### 1.3 `core/permissions.dart`
- `can()` at `core/permissions.dart:31` decides from `member.role`, `member.grants`, and `openCheckoff` for an anonymous shared display (`:32-37`).
- `spacesFor()` at `core/permissions.dart:86-101` derives readable spaces from device mode and owner: hub mode reads everything (`:92-94`), shared or ownerless reads only `family` (`:95`).

Strength: small and easy to reason about. Weakness: permission inputs are split across role, `member.grants` (`core/schema.dart:415`, max 4 values), device `mode`, `display.openCheckoff` (`core/schema.dart:448`), PIN `signIn` (`core/schema.dart:373`, `:416`), and connection scopes. No single "why can this device do X" answer.

### 1.4 `hub/device_auth.dart`
- `parentOf()` at `hub/device_auth.dart:142-148`: a parent-only hub call must come from a non-shared device whose `member` is the acting parent.
- Strength: correctly refuses a hub-mode device naming another member (doc comment `:136-141`).
- Weakness: "parent's own phone" is the only admin credential. A parent signed in from a browser with no device record can't do admin work.

### 1.5 `hub/invites.dart` (four-word message invites)
- Doc at `hub/invites.dart:15-37`; routes `POST /api/v1/invites` and `/api/v1/invites/redeem` at `:80-81`.
- Words stored as a stretched slot; wrong guesses limited per client and globally (`:23-26`, `hub/edge.dart:186+`).
- `maxJoins = 3` at `hub/invites.dart:66`: up to 3 devices may wait per invite.
- Strengths: invites expire within a week; hub doesn't learn app-picked words.
- Weaknesses: 44-bit codes are guessable in principle and rely on rate limits; a leaked code still creates pending requests; "a parent still approves the device that asks" (`:23`) means a live tap is still needed unless an invite key is attached.

### 1.6 `core/invite_keys.dart`
- Doc `core/invite_keys.dart:1-17`: a parent's device writes an `inviteKey` record; the key signs an `InviteProof` that lets a device self-approve with `approved: true`.
- Strength: revocation is thought through (`:12-17`, `kept` list).
- Weakness: a second proof format and a second self-approval exception (validity `:146-149`). 389 lines for what a grant would express as one record.

### 1.7 Recovery (`core/recovery.dart`, `hub/recovery.dart`)
- Hub side doc `hub/recovery.dart:76-86`: opt-in Ed25519 server recovery key in `hub/recovery.json`, public half in `family.recovery.serverKey`; operator mints a one-time code with `den_hub recover --person NAME`.
- Recovery words (BIP-39, 12 words) described in `ARCHITECTURE.md:278-280`.
- Strength: works without the server (words) or with it (key), and every device sees how someone got in.
- Weakness: a third proof format and third self-approval branch (validity `:142-145`). The opt-in hub key is already the shape the account-first design needs, but it's off by default.

### 1.8 Setup and the "Add a device" window (`hub/setup.dart`)
- `SetupStage` at `hub/setup.dart:62-80` includes `waitingForApproval` (`:69-70`).
- `setup()` at `hub/setup.dart:279-285` returns 409 "This hub is already part of a family." (`:280`). This is expected on reruns because `deploy/private/install.sh:533-537` always asks for a setup link.
- `LinkSlots` at `hub/setup.dart:417-470`: in public posture a browser may request a slot only while a parent's device has opened the 10-minute window (`:433`, `:443-455`) or the operator wrote `hub/link-open` (`:441-450`). Window opened by `openWindow` signed via `auth.parent` (`:459-460`).
- Strength: no code harvesting from the internet. Weakness: requires a parent's device in hand; a signed-in parent browser can't open it.

### 1.9 Access tokens, OAuth, MCP (`hub/access.dart`, `hub/oauth.dart`)
- `accessForToken` at `hub/access.dart:45`; doc `:38-44`: a connection acts as its named member, or as the approving parent while they remain a parent. If the parent leaves or is demoted, it reads nothing.
- OAuth: PKCE S256 required (`hub/oauth.dart:236`, `:397-399`); https/loopback redirect URIs only (`:266-268`); connection requests listed and decided only by a parent's own device (`:486-487`, `:494-499`).
- Strength: the "capped by approver's current status" rule already exists here. It is the model the grant design generalises.
- Weakness: the cap is role-level (parent or not), not per-permission. A connection's scope can't be narrower than "acts as member X".

### 1.10 `hub/edge.dart` rate limits
- `Limits` at `hub/edge.dart:160-184`: anonymous 600/min, failures 30/5 min, pairing 20/10 min, OAuth register 10/h, authorize 10/15 min, token 60/5 min, sockets 120/min, 64 open sockets.
- Client key from right-most untrusted `X-Forwarded-For` hop (`:77-90`, `:125-135`), trusted proxies from `DEN_TRUSTED_PROXIES`.
- Wrong-guess counters for short codes (`:187+`).
- Gap: no budget for `/auth/*` (doesn't exist yet). Behind Cloudflare Tunnel, the trusted proxy is cloudflared on the compose network (`deploy/hosted/compose.yaml:39-40`); verify clientKey still resolves the real client [INF: cloudflared sets `X-Forwarded-For`; confirm in a test].

### 1.11 Kids, roles and PINs today
- Roles: `enum Role { parent, adult, kid, guest }` at `core/model.dart:80`.
- Kid permissions in `can()`, `core/permissions.dart:43-54`: kids may check items, complete their own chores, swap chores and request rewards; editing events/chores/lists and managing points only through `member.grants`; `completeAnyChore` and `manageFamily` always false (`:53`).
- Member sign-in for shared screens: `member.signIn {kind: pin|pattern|none, salt, hash}` (`core/schema.dart:373-377`, field at `:416`).
- Hashing: PBKDF2-HMAC-SHA256, 20,000 iterations, 16-byte random salt, 256-bit output (`core/secrets.dart:6-8`, `:22-34`); constant-time compare (`:36-45`). PIN is exactly 4 digits, pattern 4 animals 0-8 (`:10-21`).
- Set by `Den.setSignIn` (`core/den.dart:949-964`): a member can set their own; only a parent (`manageFamily`) can set someone else's.
- Checked by `Den.verifySignIn` (`core/den.dart:509-519`): `none` passes except for a parent on a shared display.
- Wrong tries: `Den.noteSignInTries` (`core/den.dart:521-532`) writes a `signInTries` record (`core/schema.dart:420-424`) so parents see it in History. It is a notification only; I found no lockout in core [INF: app-side delay not re-read].
- **Risk (low, accepted by Jared; see decision 7):** the salt and hash live in the replicated family space, so every family device and any backup holds them. A 4-digit PIN has 10,000 values; at 20k PBKDF2 rounds that is brute-forced offline in seconds to minutes on any laptop [INF on exact time]. A stronger KDF raises the cost but can't fix a 10^4 keyspace. Jared accepts this: Den is a scheduling app with no payments, and PINs must work offline. Hardening may raise the cost but must not move the check off the device.
- Kids today are plain members; there is no "kid account" concept and no binding to a parent. That matches the locked decision below.

### 1.12 Risk summary
| Risk | Where | Severity [INF] |
| --- | --- | --- |
| Losing all devices = losing identity | 1.1, 1.7 | High (support burden) |
| Four entry paths, four rule sets to keep correct | validity `:142-158` | High (bug surface) |
| Stored approval doesn't follow demotion | validity `:509-513` | Medium |
| Pending requests from leaked invite words | invites `:64-66` | Medium |
| Admin only from a parent's phone | device_auth `:142-148` | Medium (usability) |
| No `/auth/*` rate budget | edge `:160-184` | Medium once OIDC lands |
| PIN verifier replicated, offline-guessable | `core/secrets.dart:6-34`, `schema.dart:373-377` | Low, accepted (decision 7) |
| No PIN lockout, only a notice | `core/den.dart:521-532` | Medium |

---

## 2. Target design: accounts plus one grant model

Principals:
- **Account**: a person signed in with Google or Apple. Invite-only. Bound to one family member (`member.account = {provider, sub}` hash).
- **Device**: phone, tablet, wall screen, MCP client. Has no authority of its own, only what a grant gives it.

One replicated record in the family space:
```
grant {
  id,
  to:      device:<id> | account:<id> | connection:<id>,
  by:      <accountId>,          # who authorized it
  actsAs:  <memberId> | null,    # null = "the screen", acts for nobody
  perms:   ["read:f", "read:m:<kid>", "events.write", "chores.complete:anyone", "lists.write", "points.manage", ...],
  expires, revoked
}
```

Rules:
- **effective(grant) = grant.perms ∩ currentPerms(grant.by)**, computed at evaluation time, never stored. Demotion of `by` narrows automatically.
- **Cascade revoke on granter removal (decision 8):** when the account in `by` is removed from the family (or loses its binding), every grant it authorized is revoked in the same commit, and each of those devices is signed out of the server (sessions, sockets, tokens dropped). When the device learns of the removal it shows a warning and a "take over" QR code, and keeps its data and setup (decision 9). A parent-level adult who scans it re-authorizes the device under their own account: the device key is regenerated and the new grant (`by` = that adult, perms ≤ their current perms) replaces the old one. The warning stays up, across syncs and restarts, until a parent-level adult takes the device over or a parent wipes it remotely from their device list; there is no auto-wipe. While waiting, the device shows only the warning and the QR: family data stays on the device for a takeover but is hidden.
- **Re-pair:** any surviving member with parent-level perms (a parent, an adult kid or uncle with parent perms, up to the server admin via CLI) scans the signed-out device's QR and writes a new grant with themselves as `by`. Perms are capped by the new granter, as for any grant.
- A person's own phone: `to: device, by: self, actsAs: self, perms: all of mine`.
- A shared screen: `by: <parent>, actsAs: null`, perms the parent ticked. Labels like "kitchen" are labels only.
- MCP/OAuth/integration/ICS: `to: connection`, `by` = approving parent. The `connection` record keeps `tokenHash` and points to its grant.
- Device keys and the signed log stay. Validity, at the change's place in the log, checks: (1) device named by a live grant; (2) grant's `by` is a live member with a bound account; (3) the action is in effective perms.
- Who signs a grant: a parent's device, or the **hub signing key** (in `<data>/hub/`, owner-only), public half in the family record, reusing the `family.recovery.serverKey` slot (`ARCHITECTURE.md:242+`). The current opt-in recovery key (`hub/recovery.dart:76-86`) becomes this key and is always on.

### 2.1 Kid profiles (family-level principals)
- A **kid profile** is a `member` with `role: kid` and no `account`. It belongs to the family, not to any parent: no `owner`/`parent` field, and it survives any one parent leaving.
- A kid profile is never a grant `by`. It can't issue, approve, or widen a grant, device, or connection. Validity refuses any `grant`, `device` approval, or `connection` change whose actor is a kid, whatever the perms say.
- A kid acts only on a device or screen that already holds a parent-issued grant. The kid unlocks it with a PIN; the device then acts with `actsAs: <kid>` and effective perms = **grant.perms ∩ kidPerms** (the fixed kid set in `core/permissions.dart:43-54`, plus any per-kid extras a parent ticks). When the PIN session ends, the device returns to its own grant.
- Kid mode is a limited "dumb mode": no settings, no Access screen, no device list, no connections, no invites.
- Optional conversion: a parent adds an email to the kid profile and sends a normal invite. When the kid signs in with Google/Apple under the invite rule, the hub binds the account to the **same member id**; history, chores, stars (points) and lists stay because they reference the member id. The role stays `kid` unless a parent changes it [INF: whether a converted kid keeps kid perms by default].
- PIN storage (decided, decision 7): each kid has one PIN. Its salted verifier is synced to every family device in the family space (as today, `core/schema.dart:416`) and verified locally, so kid sign-in works with no network. A parent sets or resets it once, and the change syncs everywhere. There is no hub-held verifier and no online check. Accepted risk: anyone with a family device or backup can brute-force a 4-digit PIN offline. Allowed hardening, as long as it keeps working offline: (a) a versioned, stronger KDF (argon2id, e.g. m=64 MiB, t=3, p=1, or scrypt N=2^15, r=8, p=1, with a 16-byte salt [INF on choice and parameters; check wall-screen CPU cost]); (b) a per-device lockout/backoff counter (not synced).

### 2.2 Revoke and re-pair: today vs target
Today:
- `Den.removeMember` (`core/den.dart:917-937`) revokes only the devices the member **owns** (`d.member == id`, `:920-922`), retires invites they made (`:928`), and rotates the spaces those devices held (`:936`). Devices they **approved** for others (`approvedBy`) stay approved [INF: no cascade on `approvedBy` found in `removeMember`].
- `Den.revokeDevice` (`core/den.dart:991-998`) writes `{revoked: true, revokedAfter: N}` (`:1001-1008`) and rotates space keys; changes signed after `N` count for nothing (`core/validity.dart:38-55`).
- A revoked or removed device is refused (`core/validity.dart:162-164`) and can't ask to join again (`core/validity.dart:256`). Re-pairing today means removing it and adding it as a new device [INF: app flow not re-read]; the owner can't be changed while approved (`core/validity.dart:493-495`).

Target edge cases:
- Owner of a phone removed: its own-device grant ends; the phone is signed out.
- Parent who set up the kitchen screen removed: the screen's grant is revoked and it is signed out; it shows its QR. Another parent-level adult scans it and re-grants.
- Last parent-level person removed: only the server admin can re-pair (`den_hub devices` CLI, plus a QR-pair command [INF]).
- A kid PIN session on a removed parent's screen ends when the warning appears (decision 9); after a takeover, kid PINs work again under the new grant; after a remote wipe the screen shows the sign-in/QR screen.
- Re-pair under a new granter must not inherit the old grant's perms; the new granter ticks perms again (defaults to their own cap) [INF].
- Offline device: it keeps working on local data until it syncs and learns of the removal, then shows the warning and take-over QR (decision 9). Changes signed after `revokedAfter` count for nothing (`core/validity.dart:38-55`) and are dropped even if the device is taken over (decision 9); a takeover keeps the synced data and setup, not those changes. The warning then stays up until a takeover or a remote wipe.
- Wipe scope: the local log, materialized store, space keys, cached photos and the kid PIN verifiers [INF: exact storage locations in `app/lib` and `den_net` not re-read]. Nothing of the family's remains on the device.
- Takeover: the device key is regenerated (this settles the earlier keep/regenerate question), the old key stays revoked, and the new grant applies at once.
- Remote wipe: a parent wipes the device from their device list; it removes all family data and shows the sign-in/QR screen.
- After a remote wipe, a re-pair or a new sign-in starts from empty and re-syncs from the server like a new device.

Migration: first deploy writes one grant per approved device (`by` = `approvedBy`, `actsAs` = `member`, perms = what its mode allows today). Each parent then signs in once from a device they already use to bind their account. Nothing re-pairs.

---

## 3. Jared's locked decisions (do not re-open)

1. **The invite is the approval.** Verified email + active invite for this family = hub signs the account grant and first device grant at once, burns the invite. Otherwise nothing: no request, no pending state. The reply is the same generic "no invite found" whether or not an invite or family exists.
2. **Apple sign-in requires Share My Email.** A Hide-My-Email relay address (`privaterelay.appleid.com`) is refused and never matched.
3. **Any device gets exactly the account's perms.** A bound account signing in on a new device gets a device grant equal to that account's perms. No tap.
4. **Visibility and pruning.** The family creator, every parent, and the server admin (hub CLI) can see and revoke any device, screen, or connection.
5. **Kids have no accounts by default.** A kid is a family-level sub-profile, not owned by or attached to one parent. A kid signs in only with a parent-set PIN, only on a device or screen a parent already authorized. Kid profiles get kid permissions only and can never approve connections or devices. A parent may add an email to a kid profile and convert it to a full account through the normal invite rule; that's the parent's choice.
6. **Every connection needs parent approval.** MCP, OAuth, integrations, calendar (ICS) feeds. Kids can never approve or create one. A connection's perms are capped by the approving parent's.
7. **One PIN per kid, synced to every family device, verified locally.** A parent sets or changes it once; it syncs everywhere through the family log (today's model), and each device checks it locally so it works offline. Any lockout is per-device. A parent reset propagates via sync. Reliability beats secrecy: Den is a scheduling app with no payments. The offline-crack risk is known and accepted (low). Only hardening that keeps offline use is allowed: a local per-device lockout/backoff and a versioned stronger KDF.
8. **Removing an owner or authorizing account signs out every device they authorized.** Any surviving adult with parent-level perms (adult kids, uncles, etc., up to the server admin) can scan that device's "take over" QR code to re-authorize it under their own account (see decision 9).
9. **Takeover or remote wipe, no auto-wipe.** When the account that authorized a device or screen is removed, the device does not wipe right away. When it learns of the removal it shows a warning and a "take over" QR code. Any approved adult with parent-level perms can scan it and re-authorize the device under their own account; the device keeps its data and setup, its device key is regenerated, and its perms become that adult's grant (capped by their current perms). The warning stays up, across syncs and restarts, until an approved parent-level adult takes the device over or a parent wipes it remotely from their device list. There is no sync-based or timed auto-wipe. While waiting, the device shows only the warning and the takeover QR; no family data is visible (it stays on the device for a takeover but is hidden). The kid PIN session ends when the warning appears; kid PINs work again after a takeover. Offline edits made after the revoke are dropped, even if the device is taken over. After a remote wipe the device shows the sign-in/QR screen, where anyone can sign in with a different account or a parent-level adult can re-pair it by QR (re-syncs from the server).
10. **Google or Apple, nothing else.** Every account signs in with Google or Apple. There is no email magic link and no password; a person with neither (a grandparent, say) uses a device or screen a parent set up. (Answers open question 2.)
11. **Grown-ups on a shared screen tap from their own phone; PINs are for kids only.** An adult acts as themselves on a shared screen by confirming from their own phone, never with a PIN. Phases 3 and 3b build the tap; until then nothing may assume a grown-up PIN. (Answers open question 1.)
12. **Both providers, Google first.** Phase 1 builds Google and Apple and tests both against fake providers. Apple waits on the owner's Apple Developer Program membership, so it stays off unless configured, and the hosting guide says it is optional until then.

---

## 4. Phased next steps

General rules for every phase: run the full existing test suite (`dart test` in each of `packages/den_core`, `packages/den_hub`, `packages/den_net`, `packages/den_actions`, plus app tests) before and after. No phase may break an existing test without an explanation in the PR. Don't touch `deploy/` before phase 5.

### Phase 1: OIDC sign-in and account binding
- [x] New `hub/oidc.dart`: Google and Apple discovery, JWKS fetch/cache via `hub/net_guard.dart`, Apple client-secret JWT (ES256 from `.p8`).
- [x] New `hub/accounts.dart`: callbacks, `__Host-` session cookie (Secure, HttpOnly, SameSite=Lax), Origin check on state-changing POSTs, account→member binding.
- [x] `core/schema.dart`: add `member.account` (`{provider, sub}` hash).
- [x] `hub/hub.dart` (routes near `:251-279`): `/auth/oidc/{google,apple}/{start,callback}`, `/auth/logout`, `/api/v1/me`.
- [x] `hub/edge.dart:160-184`: add `Limits.auth` budget for `/auth/*`.
- [x] Binding: a signed-in parent's existing device binds their account to their member. No new admission path yet.

Acceptance: an existing parent can sign in with Google and Apple and `/api/v1/me` returns their member. A sign-in with no binding returns the generic reply and creates nothing. Nothing else about devices changes.
Tests: `iss`/`aud` exact match, nonce, PKCE, expired/forged ID token, `email_verified=false` rejected, Apple relay email rejected, `sub` binding (not email), cookie flags, rate limit on `/auth/*`, identical response body/status/timing class for "no invite" vs "no family".

Phase 1 as built (`feat/auth-oidc`):
- `member.account` is `{provider, hash}`, hash = HMAC-SHA256 keyed by the family id over `"den/account/v1" 0 provider 0 sub` (`core/account.dart`). Validity: a parent binds only their own, only from a **personal** device (stricter than the other trust fields: a hub-mode device whose owner is using it can't, since the hub checks the sign-in), in a change that writes nothing else; the person or any parent may clear it; a hash another member holds is refused.
- Binding never lets the hub write: the parent's phone asks for a binding (signed), opens its start link in a browser (an interstitial; Continue posts back), reads the result back once (signed), and writes `member.account` itself. A second use of the start link spoils it.
- After the security review: `member.account` also carries the hub's `AccountProof` (its device key signs family, member, provider, hash, nonce, expiry), checked on arrival and by validity against an approved hub at that place in the log, so nobody binds a hash they computed. Two bindings of one account both stand and sign in as neither; parents see it in Needs you. Only a current parent signs in: a parent made something else keeps a dormant binding. **Phases 2 and 3: grants must cap a binding's effect by the person's current permissions**, not by anything recorded at binding time.
- "No invite" doesn't exist yet in phase 1; the tested pair is "bound to nobody" vs "hub in no family", which share one page and the same work. Phase 3's "no invite" must reuse `HubAccounts.noAccountPage`.
- Routes are registered only when a provider is configured and `DEN_PUBLIC_URL` is https; `auth` joined the host's reserved paths and the web app's service-worker pass-through.
- Drift from 7248c3c, code wins: routes are at `hub/hub.dart:249-280` (not `:251-279`); `_device` is `core/validity.dart:480-516` (not `:479-515`), and the dispatch cites one line early (`:143-149`, not `:142-149`). The rest of the citations used by phase 1 held.

### Phase 2: `grant` record, dual-write
- [ ] `core/schema.dart`: `RecordType.grant` with the fields in section 2.
- [ ] `core/permissions.dart`: `effectivePerms(grant, store)` = perms ∩ authorizer's current perms; `spacesFor` derives from `read:*`.
- [ ] `core/validity.dart`: accept a device if *either* the old approval or a live grant authorizes it.
- [ ] Migration: write one grant per approved device on first start (idempotent).
- [ ] Hub signing key always on; public half in family record.

Acceptance: every existing device keeps working; every approved device has exactly one migrated grant; removing a grant's `by` drops access with no rewrite.
Tests: migration idempotence; demote parent → screen they authorized loses parent-only perms; remove parent → every grant they authorized is revoked and those devices are signed out (decision 8); convergence/replay tests (`core/test/convergence_test.dart`, `replay_equivalence_test.dart`) pass with grants.

### Phase 3: grant-based flows in hub and app
- [ ] `hub/invites.dart`: invites gain `email`; redeem = verified-email sign-in matching an active, unexpired, unused invite → hub signs account + device grants, burns invite. Remove `maxJoins` (`:66`).
- [ ] `hub/setup.dart:417-470`: link grant posts a full grant (perms + label); a signed-in parent session may open the window.
- [ ] `hub/device_auth.dart:142-148`: "parent's own device" becomes "holder of a grant from a parent account with the needed perm".
- [ ] `hub/access.dart:38-45`, `hub/oauth.dart:486-533`: token → connection → grant → authorizer. Approve from a signed-in parent browser. Kids refused.
- [ ] New `den_hub devices list|revoke` in `packages/den_hub/bin/den_hub.dart`.
- [ ] App (`app/lib`): sign-in screen; one "Access" screen per person/device/connection with perm checkboxes; QR scan → perms sheet; devices list for creator/parents; a device whose authorizer was removed shows a warning and a "take over" QR; any parent-level adult can scan it to re-authorize the device under their own account.
- [ ] Cascade on granter removal: `removeMember` (`core/den.dart:917-937`) also revokes every grant whose `by` is that account, and the hub drops their sessions, sockets and tokens. Tests: remove parent A → A's screens and phones are signed out on the next request/socket frame; parent B re-pairs via QR → new grant `by: B`, perms ≤ B's; adult with parent perms can re-pair; kid or plain adult refused; server admin re-pairs when no parent remains; offline device's post-revoke changes discarded. Takeover: warning and take-over QR shown when the device learns of the removal; takeover by a parent-level adult keeps data and setup, regenerates the device key (old key stays revoked) and applies the new grant with perms ≤ that adult's; a kid or plain adult is refused; a device taken over does not wipe. Warning state: persists across syncs and restarts with no auto-wipe; no family data visible (check every screen and notification); the kid PIN session ends when the warning appears and kid PINs work again after takeover; post-revoke offline edits are dropped even after takeover. Remote wipe: a parent wipes the device from their device list; after the wipe no family data remains (log, store, keys, photos, PIN verifiers; check storage directly); the sign-in/QR screen is shown; a QR re-pair restores the family data from the server; sign-in with a different account works on the wiped device.

Acceptance: the five locked decisions in section 3 each have a passing test. A kid account attempting to approve any connection type gets 403 and no record.
Tests: invite single-use, 7-day expiry, revocable, lowercase match; new-device sign-in gets exactly account perms; ICS feed token creation needs parent; CLI list/revoke.

### Phase 3b: kid profiles and PINs
- [ ] `core/schema.dart`: mark kid profiles (role `kid`, no `account`); add `member.email` (optional, parent-set) for conversion.
- [ ] `core/validity.dart`: refuse `grant`, device approval and `connection` changes with a kid actor (alongside `_connection`, `:649+`, and `_device`, `:479+`).
- [ ] `core/permissions.dart`: `kidPerms` as a named set; effective = grant ∩ kidPerms while a kid PIN session is active.
- [ ] `core/secrets.dart`: new KDF (argon2id or scrypt [INF on choice and library]), per-PIN 16-byte salt, versioned hash format (`v2$argon2id$...`); keep PBKDF2 verify for old hashes and rehash on next successful sign-in.
- [ ] One synced PIN per kid; the check stays local on each device (`Den.verifySignIn`, `core/den.dart:509-519`); no hub endpoint. Add an optional per-device lockout/backoff: 5 wrong tries then 1 min, doubling to a 1 h cap; after 20 the profile locks on that device until a parent unlocks [INF on numbers]. The counter is local, so it works offline. The existing `signInTries` notice (`core/den.dart:521-532`) is kept.
- [ ] Parent PIN reset: a parent sets a new PIN from their device or signed-in browser via `setSignIn` (`core/den.dart:949-964`); the new PIN syncs to every family device, each device clears its local lockout when it receives the reset, and History records it. Kids can't change their own PIN [INF: today `setSignIn` lets a member set their own, `:958`; restrict for kids].
- [ ] Conversion flow: parent adds email → invite → kid signs in → account bound to the existing member id; old PIN optional afterwards.
- [ ] App: kid PIN pad on authorized devices; kid mode UI without settings/access/connections.

Acceptance: a kid can use only parent-authorized devices, only with a PIN that is checked offline, and only with kid perms. Every kid attempt to approve a device/connection or write a grant is refused by validity on every replica. A converted kid keeps all history and stars.
Tests: one PIN set on device A verifies on devices B and C after sync; parent reset on A invalidates the old PIN on B after sync; lockout on A does not lock B; KDF params and salt uniqueness; old PBKDF2 hashes verify and are upgraded; PIN sign-in works in airplane mode on an authorized device; no network call during PIN verify; local lockout timing survives app restart and parent unlock clears it; PIN reset by parent ok, by kid refused; kid actor creating grant/device/connection rejected; conversion keeps member id, points balance and History; a kid on an unauthorized device gets nothing.

### Phase 4: require grants, delete folded code
- [ ] `core/validity.dart`: require grants. Remove `_join` (`:253-271`), the self-approval dispatch for `recovery`/`invite` (`:142-149`) in favour of one "grant proof" check, and the parent-device approval branch (`:509-513`).
- [ ] Recovery words remain, as a key that can sign a self-grant for a parent.
- [ ] Old `approved/approvedBy` fields become read-only, then ignored.

Acceptance: test suites green with old paths removed; `invite_keys_test.dart` and `recovery_test.dart` rewritten against grant proofs, covering the same revocation cases (`core/invite_keys.dart:12-17`).

Deletions in this phase:
- `core/invite_keys.dart` (folded into grant proof) [INF: keep a thin compatibility reader for one release].
- `SetupStage.waitingForApproval` (`hub/setup.dart:69-70`) and the app's approve-a-new-device flow and pending prompts in "Needs you" [INF: app file paths not re-read].
- Four-word code path for account invites (`hub/invites.dart`) [INF: keep only for screens, if at all].
- `device.approved/approvedBy`, `member.grants`, `display.openCheckoff` combinations replaced by perms; `DeviceMode` personal/shared split collapses to "has `actsAs`". PIN `signIn` stays only if Q2 says so.

### Phase 5: deploy move to Cloudflare Tunnel
Do not start until phases 1-4 are merged and live.
- [ ] Use `deploy/hosted/compose.yaml` with the `tunnel` profile (`:75-87`, `TUNNEL_TOKEN`), `DEN_PUBLIC_URL` (`:37`) and `DEN_TRUSTED_PROXIES` (`:40`). This is setup B in `docs/hosting.md:35`.
- [ ] Env: `TUNNEL_TOKEN`, `COMPOSE_PROFILES=tunnel` (and, per docs/settings.md, these too move out of files where they can). Google and Apple sign-in are set up in the app (Settings, Advanced, Sign in with Google or Apple), not in env: there are no `DEN_GOOGLE_*`/`DEN_APPLE_*` variables. Redirects, which that screen lists with Copy buttons: `https://den.kotvas.app/auth/oidc/google/callback`, `.../auth/oidc/apple/callback` (form_post).
- [ ] Cloudflare WAF rules on `/auth/*`, `/api/v1/invites/redeem`, `/api/v1/recovery/redeem`, `/api/v1/hub/setup*`.
- [ ] Same domain, same data volume, so no device re-pairs [INF: confirm with `docker volume ls` on the server].
- [ ] **Dual-run**: run the tunnel alongside the private setup for an agreed period [INF: suggest 2 weeks]; every family device must have connected through the tunnel at least once before removal.
- [ ] After dual-run, remove: dnsmasq (`deploy/private/compose.yaml:92+`, `dnsmasq.conf`); Tailscale split-DNS step (`deploy/private/install.sh:507-521`); 443 allowlist (`deploy/private/nftables/den_fw.nft` home sets `:30-37` and their rules, `den-allowlist`, `systemd/den-allowlist.{service,timer}`, installed by `install.sh:427-432`); DDNS homes (`deploy/private/env.example:15-26`); Caddy DNS-01 (`deploy/private/Caddyfile:20+`, `caddy.Dockerfile`).
- [ ] Keep Tailscale for admin SSH only (`deploy/private/tailscale-acl.hujson`) [INF]. Keep backups (`deploy/private/backup.sh`). Rotate shared ICS tokens.

Acceptance: `https://den.kotvas.app` reachable only via tunnel (no open 443); sign-in works from off-network; edge rate limits key on the real client IP through cloudflared; backups restore.

### Per-file change list (summary)
| File | Change | Phase |
| --- | --- | --- |
| `core/schema.dart` | `member.account`, `RecordType.grant`; later drop approval fields | 1, 2, 4 |
| `core/validity.dart` | grant check; delete `_join`, proof branches, device approval | 2, 4 |
| `core/permissions.dart` | effective perms; `spacesFor` from `read:*` | 2 |
| `core/invite_keys.dart`, `core/recovery.dart` | fold into grant proof | 4 |
| `hub/oidc.dart`, `hub/accounts.dart` | new | 1 |
| `core/secrets.dart` | argon2id/scrypt, versioned hash, rehash | 3b |
| `core/den.dart` | `setSignIn` kid restriction, parent reset, conversion bind, local PIN lockout; `removeMember` cascade over grants `by` | 3, 3b |
| `hub/hub.dart` | auth and grant routes | 1, 3 |
| `hub/edge.dart` | `/auth/*` budget | 1 |
| `hub/invites.dart` | email invites, auto-admit, drop `maxJoins` | 3 |
| `hub/setup.dart` | full grant in link flow; browser-session window; drop `waitingForApproval` | 3, 4 |
| `hub/device_auth.dart` | grant-based parent check | 3 |
| `hub/access.dart`, `hub/oauth.dart` | token → grant → authorizer | 3 |
| `hub/recovery.dart` | key becomes always-on hub signing key; `den_hub recover` stays | 2 |
| `packages/den_hub/bin/den_hub.dart` | `devices list|revoke` | 3 |
| `app/lib` | sign-in, Access screen, devices list, orphaned screens | 3 |
| `deploy/*` | tunnel; remove private-network pieces after dual-run | 5 |

---

## 5. Open questions
1. ~~Keep the PIN on screens for adults ("act as me on the kitchen tablet"), or require a phone tap?~~ Answered: a tap from their own phone; PINs are for kids only (decision 11).
2. ~~A grandparent without Google or Apple: email magic links, or require an account?~~ Answered: require Google or Apple; no magic links (decision 10).
3. Tunnel (setup B) or Cloudflare proxy in front of Caddy (setup A)? This plan assumes B.
4. Dual-run length before deleting the private setup [INF: 2 weeks proposed].
