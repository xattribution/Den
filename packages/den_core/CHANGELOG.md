## Unreleased

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
