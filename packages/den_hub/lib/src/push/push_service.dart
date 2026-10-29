import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import '../body.dart';
import '../context.dart';
import '../device_auth.dart';
import '../http_util.dart';
import '../hub.dart';
import '../reminders.dart';
import '../setup.dart' show restrictToOwner;
import 'web_push_crypto.dart';

/// Reminders and nudges to the browsers family members turned them on in: Den as a Home Screen
/// app on an iPhone (iOS 16.4 and later), or any browser with Web Push.
///
/// - The hub's VAPID key pair (RFC 8292) is made once and kept in `<data>/hub/push.json`,
///   readable by the hub's user only, with each device's subscription.
/// - A device turns reminders on with `PUT /api/v1/push`, signed with its own key like every
///   device request to the hub ([DeviceAuth]); `GET` says whether it has, `DELETE` turns them
///   off, `POST /api/v1/push/test` sends one to see it work.
/// - Each reminder the hub's [ReminderService] sends goes to the subscribed devices of the
///   people it is for, encrypted for each browser (RFC 8291) so the push service sees nothing.
/// - Nudges: a device asking to join (to parents), a reward asked for (to whoever decides
///   rewards), and a chore given to someone for today or tomorrow (to them: their turn).
class WebPushService implements HubService, ReminderSink {
  /// Creates the service for [hub], checking device requests with [auth].
  WebPushService(this.hub, this.deviceAuth);

  /// Shared hub context.
  final HubContext hub;

  /// Checks signed device requests (and counts failed ones against the client).
  final DeviceAuth deviceAuth;

  @override
  String get name => 'Web Push';

  /// Push services a subscription may point at, by host suffix, so the hub never posts to an
  /// address of a device's choosing.
  static const List<String> services = [
    'push.apple.com',
    'fcm.googleapis.com',
    'push.services.mozilla.com',
    'notify.windows.com',
  ];

  /// Who to name as the sender when the hub has no https address of its own.
  static const String fallbackSubject = 'https://github.com/xattribution/den';

  static const String _doc = 'push';

  final Set<String> _changed = {};
  StreamSubscription<Set<String>>? _changes;
  Timer? _settle;
  VapidKeys? _keys;

  Map<String, Object?> get _state => hub.state.read(_doc);

  Map<String, Object?> _map(String name) {
    final v = _state[name];
    if (v is Map<String, Object?>) return v;
    final made = <String, Object?>{};
    _state[name] = made;
    return made;
  }

  /// Device id → its subscription: `endpoint`, `p256dh`, `auth`, `contact`, `since`.
  Map<String, Object?> get _devices => _map('devices');

  /// The hub's VAPID keys, made and saved on first use.
  VapidKeys get keys {
    final have = _keys;
    if (have != null) return have;
    final saved = _state['vapid'];
    if (saved is String) {
      try {
        return _keys = VapidKeys.fromPrivate(unb64url(saved));
      } on Object {
        hub.log.warn('The saved Web Push key was unreadable; made a new one. Browsers turn reminders on again.');
      }
    }
    final made = _keys = VapidKeys.generate();
    _state['vapid'] = b64url(made.privateKey);
    unawaited(_save());
    return made;
  }

  Future<void> _save() async {
    await hub.state.save(_doc);
    final dir = hub.config.dataDir;
    if (dir != null) restrictToOwner('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}$_doc.json');
  }

  /// Adds the push routes.
  void register(Routes routes) {
    routes
      ..add('GET', '/api/v1/push', (r, _) => status(r))
      ..add('PUT', '/api/v1/push', (r, _) => subscribe(r))
      ..add('DELETE', '/api/v1/push', (r, _) => unsubscribe(r))
      ..add('POST', '/api/v1/push/test', (r, _) => test(r));
  }

  Future<Device> _check(Request request) async => (await deviceAuth.check(request)).device!;

  Response _answer(String deviceId) =>
      jsonResponse({'key': b64url(keys.publicKey), 'subscribed': _devices.containsKey(deviceId)});

  /// `GET /api/v1/push`: the hub's public key, and whether this device gets reminders.
  Future<Response> status(Request request) async => _answer((await _check(request)).id);

  /// `PUT /api/v1/push`: this device's push subscription, as the browser gives it.
  Future<Response> subscribe(Request request) async {
    final signed = await deviceAuth.withBody(request);
    final bytes = signed.body;
    final device = signed.check.device!;
    if (device.mode != DeviceMode.personal || device.member == null) {
      throw ApiError.denied("Reminders go to a person's own device. A shared screen shows them where it hangs.");
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw ApiError.invalid("The body isn't valid JSON.");
    }
    if (json is! Map) throw ApiError.invalid('The body must be a JSON object.');
    final b = Body(json.cast<String, Object?>());
    final endpoint = Uri.tryParse(b.string('endpoint', required: true, min: 1, max: 2000)!);
    if (endpoint == null ||
        endpoint.scheme != 'https' ||
        !services.any((s) => endpoint.host == s || endpoint.host.endsWith('.$s'))) {
      throw ApiError.invalid("Den sends reminders only through browsers' own push services.", field: 'endpoint');
    }
    final keysJson = b['keys'];
    final p256dh = keysJson is Map ? keysJson['p256dh'] : null;
    final auth = keysJson is Map ? keysJson['auth'] : null;
    if (p256dh is! String || auth is! String || !_validKeys(p256dh, auth)) {
      throw ApiError.invalid("That subscription's keys aren't a browser's.", field: 'keys');
    }
    final base = hub.base(request);
    _devices[device.id] = {
      'endpoint': endpoint.toString(),
      'p256dh': p256dh,
      'auth': auth,
      'contact': base.scheme == 'https' ? base.toString() : null,
      'since': hub.now(),
    };
    await _save();
    hub.log.info('A device turned reminders on');
    return _answer(device.id);
  }

  static bool _validKeys(String p256dh, String auth) {
    try {
      final point = unb64url(p256dh);
      return point.length == 65 && point[0] == 4 && unb64url(auth).length == 16;
    } on FormatException {
      return false;
    }
  }

  /// `DELETE /api/v1/push`: no more reminders on this device.
  Future<Response> unsubscribe(Request request) async {
    final device = await _check(request);
    if (_devices.remove(device.id) != null) await _save();
    return _answer(device.id);
  }

  /// `POST /api/v1/push/test`: one notification to this device, to see reminders work.
  Future<Response> test(Request request) async {
    final device = await _check(request);
    if (!_devices.containsKey(device.id)) throw ApiError.notFound(message: "This device hasn't turned reminders on.");
    final sent = await _push(device.id, {
      'title': 'Reminders are on',
      'body': 'Den will remind you here.',
      'route': '/today',
      'tag': 'den-test',
    });
    if (!sent) {
      throw ApiError(502, 'push_failed', "The browser's push service didn't take the reminder. Turn reminders off and on again.");
    }
    return jsonResponse({'ok': true});
  }

  // ------------------------------------------------------------------ sending

  /// Sends [payload] to [deviceId]'s browser: true when the push service took it. A
  /// subscription the service says is gone is forgotten.
  Future<bool> _push(
    String deviceId,
    Map<String, Object?> payload, {
    Duration ttl = const Duration(hours: 12),
    bool urgent = false,
  }) async {
    final sub = _devices[deviceId];
    if (sub is! Map) return false;
    final endpoint = Uri.tryParse(sub['endpoint'] as String? ?? '');
    final p256dh = sub['p256dh'], auth = sub['auth'];
    if (endpoint == null || p256dh is! String || auth is! String) return false;
    try {
      final body = encryptForPush(
        utf8.encode(jsonEncode(payload)),
        uaPublic: unb64url(p256dh),
        authSecret: unb64url(auth),
      );
      final subject = sub['contact'] as String? ?? hub.config.publicUrl?.toString() ?? fallbackSubject;
      final response = await hub.http
          .post(
            endpoint,
            headers: {
              'authorization': keys.authorization(
                endpoint,
                subject: subject,
                expires: DateTime.now().toUtc().add(const Duration(hours: 12)),
              ),
              'content-encoding': 'aes128gcm',
              'content-type': 'application/octet-stream',
              'ttl': '${ttl.inSeconds}',
              'urgency': urgent ? 'high' : 'normal',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 404 || response.statusCode == 410) {
        _devices.remove(deviceId);
        await _save();
        hub.log.info("A browser's push subscription ended; it can turn reminders on again");
        return false;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) return true;
      hub.log.warn('A push service refused a notification (HTTP ${response.statusCode})');
    } on Object catch (e) {
      hub.log.warn('Web Push failed: ${e.runtimeType}');
    }
    return false;
  }

  /// Subscribed devices of [members], each approved and owned by one of them.
  List<String> _devicesOf(Set<String> members) {
    final den = hub.den;
    return [
      for (final id in _devices.keys)
        if (den.device(id) case final Device d
            when d.approved &&
                !d.revoked &&
                d.mode == DeviceMode.personal &&
                members.contains(d.member) &&
                !den.accessEnded(id))
          id,
    ];
  }

  // ------------------------------------------------------------------ reminders

  @override
  bool get active => _devices.isNotEmpty;

  @override
  Future<void> remind(ReminderDue reminder) async {
    final den = hub.den;
    final parts = reminder.key.split(':');
    final id = parts.length > 1 ? parts[1] : '';
    final space = parts.first == 'chore' ? den.chore(id)?.space : den.event(id)?.space;
    if (space == null) return;
    final members = {
      for (final m in reminder.members.isEmpty ? den.members : [for (final who in reminder.members) ?den.member(who)])
        if (canRead(m, space, den.family)) m.id,
    };
    final payload = {'title': reminder.title, 'body': reminder.body, 'route': reminderRoute(reminder.key), 'tag': reminder.key};
    for (final device in _devicesOf(members)) {
      await _push(device, payload, ttl: const Duration(hours: 1), urgent: true);
    }
  }

  /// Where tapping a reminder goes in the app: `/event/<id>?at=<occurrence>` or
  /// `/chore/<id>?date=<date>`.
  static String reminderRoute(String key) {
    final parts = key.split(':');
    if (parts.length < 3) return '/today';
    final id = Uri.encodeComponent(parts[1]);
    return switch (parts[0]) {
      'event' => '/event/$id?at=${parts[2]}',
      'chore' => '/chore/$id?date=${parts[2]}',
      _ => '/today',
    };
  }

  // ------------------------------------------------------------------ nudges

  @override
  Future<void> start() async {
    hub.log.debug('Web Push key ${b64url(keys.publicKey).substring(0, 8)}');
    // What already waits when the hub starts was nudged before, or predates nudges.
    await nudge(send: false);
    _changes = hub.den.onChange.listen((types) {
      _changed.addAll(types);
      _settle?.cancel();
      _settle = Timer(const Duration(seconds: 2), () => unawaited(nudge()));
    });
  }

  @override
  Future<void> stop() async {
    _settle?.cancel();
    await _changes?.cancel();
  }

  /// Sends what newly needs someone: a device asking to join, a reward asked for, a chore
  /// given to someone. Each goes once; with [send] false they're only noted as sent.
  Future<void> nudge({bool send = true}) async {
    if (!hub.ready) return;
    final den = hub.den;
    final types = send ? {..._changed} : {RecordType.device, RecordType.redemption, RecordType.completion};
    _changed.clear();
    final sent = _map('nudged');
    final now = hub.now();
    sent.removeWhere((_, at) => at is! int || at < now - const Duration(days: 30).inMilliseconds);
    final out = <(Set<String>, Map<String, Object?>)>[];
    bool fresh(String key) {
      if (sent.containsKey(key)) return false;
      sent[key] = now;
      return true;
    }

    final parents = {for (final m in den.members) if (m.isParent) m.id};
    if (types.contains(RecordType.device)) {
      for (final d in den.pendingDevices) {
        if (!fresh('join:${d.id}')) continue;
        out.add((parents, {'title': '${d.name} wants to join', 'body': 'Approve it on Today.', 'route': '/today', 'tag': 'join:${d.id}'}));
      }
    }
    if (types.contains(RecordType.redemption)) {
      final points = den.points();
      for (final r in points.pending) {
        if (!fresh('reward:${r.id}')) continue;
        final who = den.member(r.member)?.name ?? 'Someone';
        final what = points.rewards.firstWhereOrNull((w) => w.id == r.reward)?.title ?? 'a reward';
        final deciders = {for (final m in den.members) if (m.id != r.member && can(m, DenAction.managePoints)) m.id};
        out.add((deciders, {'title': '$who asked for $what', 'body': 'Approve it in Points.', 'route': '/points', 'tag': 'reward:${r.id}'}));
      }
    }
    if (types.contains(RecordType.completion) || types.contains(RecordType.chore)) {
      final today = den.todayDate();
      for (final date in [today, den.dateOf(now + const Duration(days: 1).inMilliseconds)]) {
        for (final c in den.choresOn(date)) {
          final owner = c.owner;
          if (!c.swapped || owner == null || c.done || !fresh('turn:${c.chore.id}@$date:$owner')) continue;
          out.add(({owner}, {
            'title': 'Your turn: ${c.chore.title}',
            'body': date == today ? 'Today' : 'Tomorrow',
            'route': '/chore/${Uri.encodeComponent(c.chore.id)}?date=$date',
            'tag': 'turn:${c.chore.id}@$date',
          }));
        }
      }
    }
    await _save();
    if (!send) return;
    for (final (members, payload) in out) {
      for (final device in _devicesOf(members)) {
        await _push(device, payload);
      }
    }
  }
}
