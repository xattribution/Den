## Unreleased

- Space keys are bound to the device that made them (`SpaceKey`: a signature over the family,
  space, epoch, key hash and the devices revoked by then). `addSpaceKey` keeps a key only when that
  statement verifies; keys from two parents for one epoch are both kept and every replica uses the
  lowest hash; a key that may have reached a revoked device is rotated again (`staleSpaceKeys`).
  `setSpaceKey` stores a key without a statement, for this device only.

## 1.0.0

- Initial version.
