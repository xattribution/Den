import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:den_actions/times.dart' show wallOf;
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:den_net/io.dart' show boundedWebSocketHandler, maxSyncSocketMessageBytes;
import 'package:shelf/shelf.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'body.dart';
import 'config.dart';
import 'context.dart';
import 'device_auth.dart';
import 'edge.dart';
import 'http_util.dart';
import 'log.dart';

/// Letters for setup codes: no 0, 1, I, L, O or U, so a code read off a log can't be misread.
const String setupAlphabet = '23456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Wrong setup codes one client may send before it has to wait. The code itself stays: eight
/// letters from [setupAlphabet] are about 39 bits, and a client gets five guesses, then a
/// minute's wait that doubles with every further wrong code up to an hour, so no number of
/// addresses can find it, and nobody can make the hub change it under its owner.
const int setupTries = 5;

/// How long a client waits after [setupTries] wrong setup codes the first time.
const Duration setupLockout = Duration(minutes: 1);

/// The longest a client ever waits.
const Duration setupLockoutMax = Duration(hours: 1);

/// The file in the hub's state directory (`<data>/hub/`) that `den_hub open-linking` writes:
/// until when (UTC ms) browsers may ask to link in the public posture, opened from the server.
const String linkOpenFile = 'link-open';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "This hub was removed from the family on Oct 28; reset it to add it again", or null while
/// [den] isn't a device its family removed. The date is the family's. A phone that refuses the
/// hub tells it so (den_net, `join_rejected` with reason `removed`), handing it the signed record.
String? removedNotice(Den den) {
  final me = den.hasFamily ? den.thisDevice : null;
  if (me == null || !me.revoked || !me.approved) return null;
  final at = me.rec.fieldTimes['revoked']?.millis;
  if (at == null) return 'This hub was removed from the family; reset it to add it again';
  final day = wallOf(den.family?.timezone ?? 'UTC', at);
  return 'This hub was removed from the family on ${_months[day.month - 1]} ${day.day}; reset it to add it again';
}

class _Tries {
  int wrong = 0;
  int level = 0;
  int until = 0;
  int last = 0;
}

/// Where a hub is in joining a family.
enum SetupStage {
  /// No family; waiting for a parent's phone to send the setup code and an invite.
  waitingForCode,

  /// Reaching the inviting phone and proving the invite.
  joining,

  /// The phone has the request; a parent has to approve it there.
  waitingForApproval,

  /// Approved; receiving the family's data.
  syncing,

  /// In the family and approved.
  ready,

  /// The family removed this hub ([removedNotice]); only a reset brings it back.
  removed,
}

/// The link that starts a family on this hub with no typing (`den_hub setup-link`):
/// `https://<hub>/#/setup/<code>/<hub device id>`. The phone that opens it sends the setup code
/// (the hub's proof that it's the phone the link went to) and takes in only the hub whose device
/// id the link names, the hash of its key, so there are no words to compare. In the fragment,
/// which browsers never send to the server.
Uri setupLink(Uri base, String code, String hubDevice) =>
    base.replace(path: '/', fragment: '/setup/${HubSetup.display(HubSetup.normalize(code))}/$hubDevice');

String _newCode(Random random) =>
    List.generate(8, (_) => setupAlphabet[random.nextInt(setupAlphabet.length)]).join();

/// A fresh hub's setup: the one-time code it prints, `GET /api/v1/hub/status`,
/// `POST /api/v1/hub/setup`, and the direct channel a phone can open back to the hub
/// (`GET /api/v1/hub/setup/ws`) when neither can reach a relay.
class HubSetup {
  /// Creates the setup for [hub].
  HubSetup(this.hub, {required this.onReady}) {
    if (hub.ready) {
      _stage = SetupStage.ready;
    } else if (removedNotice(hub.den) case final notice?) {
      _stage = SetupStage.removed;
      _log.warn(notice);
    } else {
      _issueCode();
    }
  }

  /// Shared hub context.
  final HubContext hub;

  /// Called once when the hub becomes ready.
  final void Function() onReady;

  final Random _random = Random.secure();
  SetupStage _stage = SetupStage.waitingForCode;
  String? _code;
  final Map<String, _Tries> _tries = {};
  String? _lastError;
  Completer<StreamChannel<dynamic>>? _backChannel;
  JoinAttempt? _attempt;

  /// The current stage.
  SetupStage get stage => _stage;

  /// The current setup code (shown as `ABCD-EFGH`), or null once the hub is in a family.
  String? get code => _code;

  /// Why the last join attempt failed.
  String? get lastError => _lastError;

  /// The three words derived from the pairing session with the inviting phone, while that
  /// session is up. The phone shows the same three; a parent approves only if they match.
  List<String>? get matchingWords => _attempt?.matchingWords;

  HubLog get _log => hub.log;

  File? get _codeFile {
    final dir = hub.config.dataDir;
    return dir == null ? null : File('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}setup-code');
  }

  /// The code as people read it: `ABCD-EFGH`.
  static String display(String code) => '${code.substring(0, 4)}-${code.substring(4)}';

  void _issueCode() {
    var code = _newCode(_random);
    // Unique on a Den host, so a code typed at an address that names no family finds one.
    while (hub.host?.setupCodeTaken(code) ?? false) {
      code = _newCode(_random);
    }
    _code = code;
    _tries.clear();
    final shown = display(_code!);
    _log.info('Setup code for this hub: $shown (enter it in the Den app to add this hub to your family)');
    final public = hub.config.publicUrl;
    if (public != null) {
      _log.info('Or open this link on the first parent\'s phone: ${setupLink(public, shown, hub.den.deviceId)}');
    }
    final file = _codeFile;
    if (file != null) {
      try {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('$shown\n', flush: true);
        restrictToOwner(file.path);
      } on Object catch (e) {
        _log.warn('Couldn\'t save the setup code file: ${e.runtimeType}');
      }
    }
    hub.config.onSetupCode?.call(shown);
  }

  void _clearCode() {
    _code = null;
    try {
      final file = _codeFile;
      if (file != null && file.existsSync()) file.deleteSync();
    } on Object {
      _log.debug('Couldn\'t remove the setup code file');
    }
  }

  /// Rechecks readiness after the den changed (approval synced in, say).
  void refresh() {
    if (_stage != SetupStage.ready && hub.ready) {
      _becomeReady();
    } else if (_stage != SetupStage.removed) {
      final notice = removedNotice(hub.den);
      if (notice == null) return;
      _stage = SetupStage.removed;
      _log.warn(notice);
    }
  }

  void _becomeReady() {
    _stage = SetupStage.ready;
    _clearCode();
    _log.info('This hub is in the family and approved');
    onReady();
  }

  /// `GET /api/v1/hub/status` (no token). In the public posture a hub that is already in a
  /// family says only that.
  Response status(Request request) => hub.config.publicPosture && hub.ready
      ? jsonResponse({'paired': true, 'setup_needed': false, 'stage': 'ready'})
      : jsonResponse({
        'paired': hub.ready,
        'device': hub.den.deviceId,
        'name': hub.name,
        'version': hubVersion,
        'setup_needed': !hub.ready && _attempt == null && _stage != SetupStage.removed,
        'stage': switch (_stage) {
          SetupStage.waitingForCode => 'waiting_for_code',
          SetupStage.joining => 'joining',
          SetupStage.waitingForApproval => 'waiting_for_approval',
          SetupStage.syncing => 'syncing',
          SetupStage.ready => 'ready',
          SetupStage.removed => 'removed',
        },
        if (_stage == SetupStage.removed) 'removed': removedNotice(hub.den),
        'matching_words': ?matchingWords,
        if (_lastError != null && !hub.ready) 'last_error': _lastError,
      });

  /// A setup code as typed: upper case, no spaces or dashes.
  static String normalize(String text) => text.toUpperCase().replaceAll(RegExp(r'[\s\-]'), '');

  /// Whether the hub waits for a phone with the setup code [given] (as typed), compared in
  /// constant time.
  bool codeMatches(String given) => _attempt == null && _backChannel == null && _codeMatches(given);

  bool _codeMatches(String given) {
    final want = _code;
    if (want == null) return false;
    final g = normalize(given);
    if (g.length != want.length) return false;
    var diff = 0;
    for (var i = 0; i < want.length; i++) {
      diff |= g.codeUnitAt(i) ^ want.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Throws `429 rate_limited` while the client [key] waits after wrong setup codes.
  void _checkWaiting(String key) {
    final t = _tries[key];
    final now = hub.now();
    if (t == null || now >= t.until) return;
    throw ApiError.rateLimited(
      ((t.until - now) / 1000).ceil(),
      'Too many wrong setup codes from here. Wait a little, then try again.',
    );
  }

  /// Counts a wrong code from [key]; returns how many it has left before it must wait (0: it
  /// waits now, [setupLockout] doubling with each round up to [setupLockoutMax]).
  int _wrongCode(String key) {
    final now = hub.now();
    if (_tries.length > 10000) {
      _tries.removeWhere((_, t) => t.until < now && now - t.last > 2 * setupLockoutMax.inMilliseconds);
      while (_tries.length > 10000) {
        _tries.remove(_tries.keys.first);
      }
    }
    final t = _tries.putIfAbsent(key, _Tries.new)..last = now;
    t.wrong++;
    if (t.wrong < setupTries) return setupTries - t.wrong;
    final wait = min(setupLockout.inMilliseconds << t.level, setupLockoutMax.inMilliseconds);
    t
      ..until = now + wait
      ..wrong = 0
      ..level = min(t.level + 1, 8);
    _log.warn('$setupTries wrong setup codes from one address; it waits ${wait ~/ 60000} min. The code stays the same.');
    return 0;
  }

  /// `POST /api/v1/hub/setup {code, invite, direct?}`. Wrong codes are limited per client
  /// ([setupTries], then a wait); the code never changes because of them.
  Future<Response> setup(Request request) async {
    if (hub.ready) throw ApiError(409, 'already_set_up', 'This hub is already part of a family.');
    final key = hub.clientOf(request);
    _checkWaiting(key);
    if (_attempt != null || _backChannel != null) {
      throw ApiError(409, 'busy', 'This hub is already joining a family. Approve it in the Den app.');
    }
    final b = Body(await readJsonObject(request, required: true));
    final given = b.string('code', required: true, min: 1, max: 40)!;
    final inviteUrl = b.string('invite', required: true, min: 1, max: 4000)!;
    final direct = b.flag('direct', fallback: false)!;
    if (!_codeMatches(given)) {
      final left = _wrongCode(key);
      throw ApiError(
        403,
        'permission_denied',
        left == 0 ? 'That setup code isn\'t right. Wait a minute, then check it in the hub\'s log.' : 'That setup code isn\'t right.',
        details: {'tries_left': left},
      );
    }
    _tries.remove(key);
    final Invite invite;
    try {
      invite = await Invite.parse(inviteUrl);
    } on FormatException {
      throw ApiError.invalid('That isn\'t a working Den invite. Make a new one in the Den app.', field: 'invite');
    }
    if (hub.den.hasFamily && hub.den.familyId != invite.familyId) {
      throw ApiError(409, 'already_set_up', 'This hub asked to join another family. Reset its data to start over.');
    }
    if (hub.host?.familyElsewhere(invite.familyId, hub.den.deviceId) ?? false) {
      throw ApiError(409, 'already_set_up',
          'That family is on this server already, at its own address. Invite people from the Den app there instead.');
    }
    final dial = !direct && (invite.hubs.isNotEmpty || invite.relay != null);
    if (dial) {
      unawaited(_join(invite, () => openInviteChannel(invite)));
    } else {
      final waiting = _backChannel = Completer<StreamChannel<dynamic>>();
      unawaited(_join(
        invite,
        () => waiting.future.timeout(const Duration(minutes: 5), onTimeout: () => throw TimeoutException('no phone')),
      ));
    }
    return jsonResponse({
      'ok': true,
      'stage': 'joining',
      'device': hub.den.deviceId,
      'name': hub.name,
      if (!dial) 'connect': '/api/v1/hub/setup/ws',
    }, status: 202);
  }

  /// `GET /api/v1/hub/setup/ws`: the inviting phone opens this WebSocket and serves its side of
  /// the pairing session on it. The hub pins the inviter's key from the invite, so only the
  /// phone that made the invite can complete the session. Its messages are session frames,
  /// bounded as they arrive like `/ws`'s.
  Handler get backChannel => (Request request) {
        final waiting = _backChannel;
        if (waiting == null || waiting.isCompleted) {
          throw ApiError.notFound(message: 'This hub isn\'t waiting for a phone.');
        }
        return boundedWebSocketHandler(
          (WebSocketChannel socket) {
            if (waiting.isCompleted) {
              unawaited(socket.sink.close());
            } else {
              waiting.complete(socket);
            }
          },
          maxMessageBytes: maxSyncSocketMessageBytes,
        )(request);
      };

  Future<void> _join(Invite invite, Future<StreamChannel<dynamic>> Function() open) async {
    _stage = SetupStage.joining;
    _lastError = null;
    _clearCode();
    _log.info('Joining a family with an invite from a parent\'s phone');
    try {
      final channel = await open();
      final attempt = _attempt = await hub.node.joinWithInvite(
        channel,
        invite,
        deviceName: hub.config.name,
        kind: DeviceKind.hub,
        mode: DeviceMode.hub,
      );
      _log.info('Matching words: ${attempt.matchingWords.join(' ')}. The Den app shows three words too; '
          'approve this hub there only if they\'re the same.');
      attempt.stages.listen((s) {
        if (s == JoinStage.waitingForApproval) {
          _stage = SetupStage.waitingForApproval;
          _log.info('Waiting for a parent to approve this hub in the Den app');
        } else if (s == JoinStage.syncing) {
          _stage = SetupStage.syncing;
        }
      });
      await attempt.completed;
      if (hub.ready) _becomeReady();
    } on Object catch (e) {
      _lastError = e is JoinException ? e.reason : (e is TimeoutException ? 'timed-out' : 'unreachable');
      _log.warn('Joining the family didn\'t finish: $_lastError');
      if (!hub.ready) {
        _stage = SetupStage.waitingForCode;
        _issueCode();
      } else {
        _becomeReady();
      }
    } finally {
      _attempt = null;
      _backChannel = null;
    }
  }
}

/// A browser waiting to be linked by a parent's phone.
class LinkSlot {
  LinkSlot._(this.id, this.secret, this.expires);

  /// The slot id shown in the QR code.
  final String id;

  /// What only the browser that asked knows; it reads the invite with it.
  final String secret;

  /// When the slot stops working (UTC ms).
  final int expires;

  /// The invite a parent's phone left, once it has.
  String? invite;
}

/// WhatsApp-Web-style linking of browsers through the hub (`/api/v1/link`).
///
/// In the public posture a browser can ask for a slot only while "Add a device" is open: a
/// parent's own device opens it for [windowLength] with a signed `POST /api/v1/link/window`,
/// so nobody on the internet can collect link codes from the hub.
class LinkSlots {
  /// Creates the slots for [hub]; [auth] checks the parent's signed request that opens them.
  LinkSlots(this.hub, this.auth);

  /// Shared hub context.
  final HubContext hub;

  /// Checks signed requests from the family's devices.
  final DeviceAuth auth;

  /// Most slots alive at once.
  static const int maxSlots = 32;

  /// How long a slot works.
  static const Duration lifetime = Duration(minutes: 10);

  /// How long "Add a device" stays open.
  static const Duration windowLength = Duration(minutes: 10);

  final Map<String, LinkSlot> _slots = {};
  final Random _random = Random.secure();
  int _openUntil = 0;

  /// Whether browsers may ask for a slot now: always on a home network, and in the public
  /// posture only while a parent has "Add a device" open, or until the time (UTC ms) the
  /// owner wrote into `<data>/hub/link-open` with `den_hub open-linking`.
  bool get open {
    if (!hub.config.publicPosture) return true;
    final now = hub.now();
    if (now < _openUntil) return true;
    final dir = hub.config.dataDir;
    if (dir == null) return false;
    try {
      final until = int.tryParse(File('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}$linkOpenFile').readAsStringSync().trim());
      return until != null && now < until;
    } on FileSystemException {
      return false;
    }
  }

  /// `POST /api/v1/link/window`, signed by a parent's own device: opens "Add a device" for
  /// [windowLength]. Answers `{open_until, open_until_ms}`.
  Future<Response> openWindow(Request request) async {
    final c = await auth.parent(request, message: 'Only a parent\'s own phone can add a device.');
    _openUntil = hub.now() + windowLength.inMilliseconds;
    hub.log.info('${c.actor!.name} opened Add a device for ${windowLength.inMinutes} minutes');
    return jsonResponse({
      'open_until': DateTime.fromMillisecondsSinceEpoch(_openUntil, isUtc: true).toIso8601String(),
      'open_until_ms': _openUntil,
    });
  }

  String _token(int bytes) => b64e(List.generate(bytes, (_) => _random.nextInt(256)));

  /// Whether a browser waits here under the link code [id].
  bool holds(String id) {
    _prune();
    return _slots.containsKey(id);
  }

  void _prune() {
    final now = hub.now();
    _slots.removeWhere((_, s) => s.expires <= now);
  }

  /// `POST /api/v1/link`: a new slot and the `den://link` URI to show as a QR code.
  Response create(Request request) {
    if (!hub.ready) throw ApiError.notReady();
    if (!open) {
      throw ApiError(403, 'link_closed',
          'A parent needs to open Add a device in Den first, on their phone. Then try again here.');
    }
    hub.limit(request, 'pairing', Limits.pairing);
    _prune();
    if (_slots.length >= maxSlots) {
      throw ApiError(429, 'rate_limited', 'Too many browsers are waiting to link. Try again in a few minutes.');
    }
    final slot = LinkSlot._(_token(16), _token(24), hub.now() + lifetime.inMilliseconds);
    _slots[slot.id] = slot;
    final base = hub.base(request);
    final uri = 'den://link?hub=${hub.den.deviceId}&slot=${slot.id}&u=${Uri.encodeQueryComponent(base.toString())}';
    return jsonResponse({
      'slot': slot.id,
      'secret': slot.secret,
      'uri': uri,
      'expires': DateTime.fromMillisecondsSinceEpoch(slot.expires, isUtc: true).toIso8601String(),
      'expires_ms': slot.expires,
    }, status: 201);
  }

  /// `POST /api/v1/link/{slot}`: a parent's phone leaves an [InviteGrant] (an invite naming the
  /// hub, signed by the phone's device key) for the slot.
  Future<Response> grant(Request request, String id) async {
    if (!hub.ready) throw ApiError.notReady();
    hub.limit(request, 'pairing', Limits.pairing);
    _prune();
    final slot = _slots[id];
    if (slot == null) throw ApiError.notFound(type: 'link', message: 'That link code expired. Show a new one.');
    if (slot.invite != null) throw ApiError(409, 'already_linked', 'Someone already answered this link code.');
    final json = await readJsonObject(request, required: true);
    final InviteGrant grant;
    try {
      grant = InviteGrant.fromJson(json);
    } on FormatException {
      throw ApiError.invalid('That isn\'t an invite grant from the Den app.');
    }
    final problem = await hub.gate.asHub(() => hub.node.acceptInviteGrant(grant, context: 'link:$id'));
    if (problem != null) {
      hub.failed(request);
      hub.log.warn('Refused a link grant: $problem');
      throw ApiError.denied('Only a parent\'s phone in this family can link a browser.');
    }
    slot.invite = grant.invite.toUrl();
    return jsonResponse({'ok': true});
  }

  /// `GET /api/v1/link/{slot}` with `X-Den-Link-Secret`: `waiting`, or `ready` with the invite.
  Response poll(Request request, String id) {
    hub.checkFailures(request);
    _prune();
    final slot = _slots[id];
    final secret = request.headers['x-den-link-secret'];
    if (slot == null || secret == null || !_same(secret, slot.secret)) {
      hub.failed(request);
      throw ApiError.notFound(type: 'link', message: 'That link code expired. Show a new one.');
    }
    return jsonResponse({
      'state': slot.invite == null ? 'waiting' : 'ready',
      'invite': ?slot.invite,
      'expires_ms': slot.expires,
    });
  }

  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// Makes [path] readable and writable by its owner only, where the system supports it.
void restrictToOwner(String path) {
  try {
    if (Platform.isWindows) {
      final user = Platform.environment['USERNAME'];
      if (user == null) return;
      Process.runSync('icacls', [path, '/inheritance:r', '/grant:r', '$user:F']);
    } else {
      Process.runSync('chmod', ['600', path]);
    }
  } on Object {
    return;
  }
}
