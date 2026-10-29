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
  'noteSignInTries': 'A shared screen tells the parents that someone kept getting a PIN wrong there; nothing acting '
      'for the family can say that',
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
  'endExpiredAccess': '$_trust; a parent\'s own device removes a sitter\'s devices after their last day, when Den opens there',
  'endAccessNow': '$_trust; it also removes the sitter\'s devices and rotates keys',
  // Photos.
  'setPhoto': 'A photo is taken or chosen on a device and made small there before it is saved; an AI connection or '
      'the assistant sees that someone has one (their picture reads "photo:<id>") but can\'t add one',
  // Recovery: a parent's new phone let in by their recovery words or the hub's key. Never an
  // assistant's or MCP client's to set up, turn on or use, whoever it acts for.
  'setRecoveryKey': '$_trust: a parent\'s recovery words are set up on their own phone, and only they keep them',
  'setServerRecoveryKey': '$_trust: whether whoever runs the hub may let a parent\'s new phone in is the family\'s '
      'call, made on a parent\'s own phone',
  'requestRecovery': 'A new device lets itself in as a parent\'s own with their recovery words or the hub\'s proof; '
      'nothing acting for the family can',
  'requestOAuthConnection': 'Written by the hub\'s OAuth server when an app asks to connect; a parent approves it',
  'setConnectionToken': 'Written by the hub\'s OAuth server, which clears the token hash an older hub recorded',
  // The hub's and the runner's own bookkeeping.
  'setSubscriptionStatus': 'Written by the hub after it fetches a subscribed calendar',
  'recording': 'The runner\'s own bookkeeping: every write runs inside a recording, which becomes its receipt',
  'fork': 'The runner\'s own bookkeeping: previews run on a fork',
  'attributed': 'The assistant\'s own bookkeeping: what it changes is marked "from the assistant" in History',
  // Sync and keys.
  'ingest': 'Sync between the family\'s own devices',
  'spaceKey': _keys,
  'setSpaceKey': _keys,
  'addSpaceKey': _keys,
  'spaceKeyToShare': _keys,
};
