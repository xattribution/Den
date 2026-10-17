import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'body.dart';
import 'config.dart';
import 'context.dart';
import 'http_util.dart';
import 'log.dart';

/// Letters for setup codes: no 0, 1, I, L, O or U, so a code read off a log can't be misread.
const String setupAlphabet = '23456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Wrong setup codes allowed before the hub prints a new one.
const int setupTries = 5;

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
}

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
  int _wrong = 0;
  String? _lastError;
  Completer<StreamChannel<dynamic>>? _backChannel;
  JoinAttempt? _attempt;

  /// The current stage.
  SetupStage get stage => _stage;

  /// The current setup code (shown as `ABCD-EFGH`), or null once the hub is in a family.
  String? get code => _code;

  /// Why the last join attempt failed.
  String? get lastError => _lastError;

  HubLog get _log => hub.log;

  File? get _codeFile {
    final dir = hub.config.dataDir;
    return dir == null ? null : File('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}setup-code');
  }

  /// The code as people read it: `ABCD-EFGH`.
  static String display(String code) => '${code.substring(0, 4)}-${code.substring(4)}';

  void _issueCode() {
    _code = _newCode(_random);
    _wrong = 0;
    final shown = display(_code!);
    _log.info('Setup code for this hub: $shown (enter it in the Den app to add this hub to your family)');
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
    if (_stage != SetupStage.ready && hub.ready) _becomeReady();
  }

  void _becomeReady() {
    _stage = SetupStage.ready;
    _clearCode();
    _log.info('This hub is in the family and approved');
    onReady();
  }

  /// `GET /api/v1/hub/status` (no token).
  Response status(Request request) => jsonResponse({
        'paired': hub.ready,
        'device': hub.den.deviceId,
        'name': hub.name,
        'version': hubVersion,
        'setup_needed': !hub.ready && _attempt == null,
        'stage': switch (_stage) {
          SetupStage.waitingForCode => 'waiting_for_code',
          SetupStage.joining => 'joining',
          SetupStage.waitingForApproval => 'waiting_for_approval',
          SetupStage.syncing => 'syncing',
          SetupStage.ready => 'ready',
        },
        if (_lastError != null && !hub.ready) 'last_error': _lastError,
      });

  static String _normalize(String text) => text.toUpperCase().replaceAll(RegExp(r'[\s\-]'), '');

  bool _codeMatches(String given) {
    final want = _code;
    if (want == null) return false;
    final g = _normalize(given);
    if (g.length != want.length) return false;
    var diff = 0;
    for (var i = 0; i < want.length; i++) {
      diff |= g.codeUnitAt(i) ^ want.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// `POST /api/v1/hub/setup {code, invite, direct?}`.
  Future<Response> setup(Request request) async {
    if (hub.ready) throw ApiError(409, 'already_set_up', 'This hub is already part of a family.');
    if (_attempt != null || _backChannel != null) {
      throw ApiError(409, 'busy', 'This hub is already joining a family. Approve it in the Den app.');
    }
    final b = Body(await readJsonObject(request, required: true));
    final given = b.string('code', required: true, min: 1, max: 40)!;
    final inviteUrl = b.string('invite', required: true, min: 1, max: 4000)!;
    final direct = b.flag('direct', fallback: false)!;
    if (!_codeMatches(given)) {
      _wrong++;
      if (_wrong >= setupTries) {
        _log.warn('$setupTries wrong setup codes; issuing a new one');
        _issueCode();
        throw ApiError(403, 'permission_denied', 'That setup code isn\'t right. The hub made a new one; find it in its log.',
            details: {'tries_left': 0});
      }
      throw ApiError(403, 'permission_denied', 'That setup code isn\'t right.', details: {'tries_left': setupTries - _wrong});
    }
    final Invite invite;
    try {
      invite = await Invite.parse(inviteUrl);
    } on FormatException {
      throw ApiError.invalid('That isn\'t a working Den invite. Make a new one in the Den app.', field: 'invite');
    }
    if (hub.den.hasFamily && hub.den.familyId != invite.familyId) {
      throw ApiError(409, 'already_set_up', 'This hub asked to join another family. Reset its data to start over.');
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
  /// phone that made the invite can complete the session.
  Handler get backChannel => (Request request) {
        final waiting = _backChannel;
        if (waiting == null || waiting.isCompleted) {
          throw ApiError.notFound(message: 'This hub isn\'t waiting for a phone.');
        }
        return webSocketHandler((WebSocketChannel socket, String? _) {
          if (waiting.isCompleted) {
            unawaited(socket.sink.close());
          } else {
            waiting.complete(socket);
          }
        })(request);
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
class LinkSlots {
  /// Creates the slots for [hub].
  LinkSlots(this.hub);

  /// Shared hub context.
  final HubContext hub;

  /// Most slots alive at once.
  static const int maxSlots = 32;

  /// How long a slot works.
  static const Duration lifetime = Duration(minutes: 10);

  final Map<String, LinkSlot> _slots = {};
  final Random _random = Random.secure();

  String _token(int bytes) => b64e(List.generate(bytes, (_) => _random.nextInt(256)));

  void _prune() {
    final now = hub.now();
    _slots.removeWhere((_, s) => s.expires <= now);
  }

  /// `POST /api/v1/link`: a new slot and the `den://link` URI to show as a QR code.
  Response create(Request request) {
    if (!hub.ready) throw ApiError.notReady();
    _prune();
    if (_slots.length >= maxSlots) {
      throw ApiError(429, 'rate_limited', 'Too many browsers are waiting to link. Try again in a few minutes.');
    }
    final slot = LinkSlot._(_token(16), _token(24), hub.now() + lifetime.inMilliseconds);
    _slots[slot.id] = slot;
    final base = requestBase(request, hub.config.publicUrl);
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
      hub.log.warn('Refused a link grant: $problem');
      throw ApiError.denied('Only a parent\'s phone in this family can link a browser.');
    }
    slot.invite = grant.invite.toUrl();
    return jsonResponse({'ok': true});
  }

  /// `GET /api/v1/link/{slot}` with `X-Den-Link-Secret`: `waiting`, or `ready` with the invite.
  Response poll(Request request, String id) {
    _prune();
    final slot = _slots[id];
    final secret = request.headers['x-den-link-secret'];
    if (slot == null || secret == null || !_same(secret, slot.secret)) {
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
