/// Engine operations no action offers, each with the reason. Every public write method of `Den`
/// is either called by some action (its spec's `engine`) or listed here; the coverage test fails
/// on anything that is neither, so nothing the app can do goes missing from the hub, MCP and the
/// assistant without a reason someone wrote down.
library;

const String _trust = 'A trust decision: only a parent on their own device makes it, never a shared screen or '
    'anything acting through the hub (den_core refuses those from a change carrying _via)';

const String _keys = 'Encryption keys move only between the family\'s own devices';

/// `Den` method name to why no action calls it.
const Map<String, String> notExposed = {
  // Lifecycle of the engine and the device.
  'open': 'Opens a device\'s own engine; not something to do to the family',
  'close': 'Closes a device\'s own engine; not something to do to the family',
  'createFamily': 'A family is founded once, on the founding parent\'s own device',
  'requestJoin': 'A device asks to join from itself, with the family\'s QR code or code words',
  'leaveFamily': 'Forgetting the family is done on the device that leaves it',
  'verifySignIn': 'Checks a PIN or picture pattern on a shared screen; it changes nothing',
  'setThisDeviceMode': 'What a device is for is set on that device by a parent',
  // Trust: people's roles and sign-in, devices, AI access.
  'removeMember': '$_trust; removing someone also revokes their devices and rotates keys',
  'setSignIn': _trust,
  'approveDevice': _trust,
  'revokeDevice': '$_trust; it also rotates keys',
  'updateDevice': _trust,
  'addTokenConnection': '$_trust: an AI can\'t make itself or another one a token',
  'approveConnection': '$_trust: an AI can\'t approve itself or widen its own access',
  'revokeConnection': _trust,
  'requestOAuthConnection': 'Written by the hub\'s OAuth server when an app asks to connect; a parent approves it',
  'setConnectionToken': 'Written by the hub\'s OAuth server when it issues a token for approved access',
  // The hub's and the runner's own bookkeeping.
  'setSubscriptionStatus': 'Written by the hub after it fetches a subscribed calendar',
  'recording': 'The runner\'s own bookkeeping: every write runs inside a recording, which becomes its receipt',
  'fork': 'The runner\'s own bookkeeping: previews run on a fork',
  // Sync and keys.
  'ingest': 'Sync between the family\'s own devices',
  'spaceKey': _keys,
  'setSpaceKey': _keys,
  'addSpaceKey': _keys,
  'spaceKeyToShare': _keys,
};
