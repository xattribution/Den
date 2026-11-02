## Unreleased

- Joining with an invite key: `InviteWords` stretches the invite's four words to the hub's slot
  and the key's seed; `pair` with `kind: key` lets any serving replica admit a device that proves
  an invite key, with wrong keys counted per client and for everyone. `DenLink` reads every Den
  link (an invite, with its `kind`; a setup link; a recovery link).

## 1.0.0

- Sessions, sync protocol, pairing, relay client, mailbox sync and encrypted backups.
