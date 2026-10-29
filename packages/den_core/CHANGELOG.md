## Unreleased

- Invite keys (`invite_keys.dart`): a parent's own device writes an `inviteKey` record, the
  public half of an Ed25519 key bound to a member (or, bound to no one, to device modes), with a
  use count (1 by default) and an expiry (at most `inviteKeyMaxLife`). A device that proves the
  key (`InviteProof`, single-use nonce) approves itself with `requestInviteJoin`; validity accepts
  it while the inviting parent is still a parent with that approved device. `withdrawInviteKey`,
  and removing or demoting the parent or revoking their device, retire the key with a `kept` set,
  like recovery keys. `disownInvite` ("That wasn't them") revokes the device and the key.
  `snapshotFormat` is 5 (4 was used by both this and the connection time zones on separate
  branches, so the merged rules start from a fresh cache).

- `family.colors` (optional, `ColorPack`: `bright`, `deep`, `soft` or `bold`; `Family.colors`
  reads `bright` when it's unset or unknown): which shades of the eight person colors the whole
  family sees. People keep their `marker`, so a pack changes shades, never who has which color.
  A parent sets it with `updateFamily`; Undo puts the old pack back.

- Faster to open, to take in late changes and to answer the screens, with the same results:
  a change that arrives late rewinds to its place instead of replaying the log; storage that
  implements the new `SnapshotStorage` (`FileStorage` does) keeps a snapshot that `Den.open`
  starts from; `ingest` checks signatures in batches (worker isolates where there are any); views
  are cached per record type and readable space; `fork` copies the state instead of replaying it.
  Benchmarks in `benchmark/` (`dart run benchmark/main.dart`, `dart test -P benchmark`).

- Space keys are bound to the device that made them (`SpaceKey`: a signature over the family,
  space, epoch, key hash and the devices revoked by then). `addSpaceKey` keeps a key only when that
  statement verifies; keys from two parents for one epoch are both kept and every replica uses the
  lowest hash; a key that may have reached a revoked device is rotated again (`staleSpaceKeys`).
  `setSpaceKey` stores a key without a statement, for this device only.

## 1.0.0

- Initial version.
