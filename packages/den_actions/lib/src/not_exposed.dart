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
  'updateConnection': '$_trust: an AI can\'t change who it acts as',
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
  'disownRecovery': '$_trust: "That wasn\'t us" removes a phone recovery let in and turns off the words or the hub\'s '
      'help that let it in, from another parent\'s own phone',
  // Invites that let someone in at once (den_core's invite_keys.dart): a parent's own device
  // vouches in advance for one device of one person. Never an assistant's or MCP client's to
  // make, use or take back, whoever it acts for.
  'createInviteKey': '$_trust: an invite that lets someone in without a tap is a parent\'s approval given ahead of '
      'time, so only a parent\'s own phone makes one, and its secret goes only into the invite they send',
  'withdrawInviteKey': '$_trust: taking back an invite before it is used is the inviting family\'s call, made on a '
      'parent\'s own phone',
  'requestInviteJoin': 'A new device lets itself in as the invited person\'s own with the invite\'s key; nothing '
      'acting for the family holds that key',
  'disownInvite': '$_trust: "That wasn\'t Dad" removes a device an invite let in and takes the invite\'s key away, '
      'from a parent\'s own phone (in a group, "That wasn\'t them" takes an invitation back, or ends that family\'s '
      'place, from the phone that sent it)',
  // Groups of families (den_core's groups.dart): which families share a group, who of each is in
  // it, and which devices get in are each family's trust decisions, made on a parent's own phone
  // with an engine of the group's own. Never an assistant's or MCP client's, whoever it acts for:
  // a connection writes into a group only as its own family's person (G4).
  'createGroup': 'A group is started on a parent\'s own phone, on an engine of its own with keys of its own',
  'inviteFamily': '$_trust: an invitation carries the key that lets another family\'s first parent in, so only a '
      'parent\'s own phone makes one, and its secret goes only into the invitation they send',
  'cancelInvitation': '$_trust: taking back an invitation to another family is the inviting family\'s call, made '
      'on a parent\'s own phone',
  'joinGroup': 'A new engine lets itself into a group with an admission sealed to its device, or an invitation\'s '
      'key; nothing acting for the family holds either',
  'updateHome': '$_trust: where a family\'s hub syncs a group, and that the family is in, are its parents\' to say, '
      'on their own phones',
  'addToGroup': '$_trust: who of a family is in a group, and the keys that let their devices in, are its parents\' '
      'decisions, made on their own phones',
  'leaveGroup': '$_trust: taking the family out of a group removes its devices and people there, in one commit '
      'from a parent\'s own phone',
  'writeAdmissions': '$_trust: admissions into a group are sealed to each device by a parent\'s own phone',
  'openGroupInvite': 'Only the device an admission is sealed to can open it, for itself',
  'writeGroupLink': '$_trust: which groups the family is in, and who of it, is a parent\'s to say on their own phone',
  'forgetGroup': '$_trust: what a family keeps of a group it left is cleaned up on the parent\'s own phone that took '
      'it out',
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
