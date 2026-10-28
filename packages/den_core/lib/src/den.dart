import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';

import 'calendar.dart';
import 'change.dart';
import 'chores.dart';
import 'hlc.dart';
import 'ids.dart';
import 'materializer.dart';
import 'model.dart';
import 'order_keys.dart';
import 'permissions.dart';
import 'points.dart';
import 'rrule.dart';
import 'schema.dart';
import 'secrets.dart';
import 'space_keys.dart';
import 'storage.dart';
import 'store.dart';
import 'time.dart';
import 'validity.dart';
import 'views.dart';

/// A reminder that comes due in a window, computed from synced data. Devices schedule these as
/// local notifications; the hub sends them through its notifiers.
class ReminderDue {
  const ReminderDue({
    required this.key,
    required this.at,
    required this.title,
    required this.body,
    required this.members,
  });

  /// Stable across devices, so the same reminder is never shown twice: `"<type>:<id>:<when>:<offset>"`.
  final String key;

  /// UTC milliseconds the reminder fires.
  final int at;
  final String title;
  final String body;

  /// Who it is for; empty means everyone who can see the item.
  final List<String> members;
}

/// What [Den.undo] will write, and what it leaves alone.
class _UndoPlan {
  _UndoPlan(this.drafts, this.skipped);
  final List<_Draft> drafts;
  final List<UndoSkip> skipped;
}

class _Draft {
  _Draft(this.type, this.rid, this.space, this.fields, {this.hlc, this.actor, this.setsActor = false});
  final String type;
  final String rid;
  final String space;
  final Map<String, Object?> fields;
  final Hlc? hlc;
  final String? actor;
  final bool setsActor;
}

/// The engine. One instance per device: it holds the change log, merges changes from any device,
/// enforces permissions, and answers every question the UI, the hub and MCP ask.
///
/// Reads are synchronous over materialized state. Writes are validated against [can] for the
/// current [actor] first (throwing [PermissionDenied] or [InvalidInput]), then signed, stored
/// and applied, and [onChange] fires.
class Den {
  Den._(this._storage, this._keys, this.deviceId, this._now) : _clock = HlcClock(deviceId, now: _now) {
    _mat = Materializer(() => _root);
  }

  final DenStorage _storage;
  final DeviceKeys _keys;
  final int Function() _now;
  final HlcClock _clock;
  late final Materializer _mat;
  TrustRoot _root = TrustRoot();
  Map<String, Object?> _meta = {};
  int _counter = 0;
  final Map<String, int> _floor = {};
  final Map<String, Change> _pending = {};
  final Map<String, String> _pubkeys = {};
  late final StreamController<Set<String>> _changes =
      StreamController.broadcast(onListen: _scheduleActingTimer, onCancel: _cancelActingTimer);
  String? _actingMember;
  int? _actingUntil;
  String? _actingVia;
  Timer? _actingTimer;
  Future<void> _tail = Future.value();
  int _cacheVersion = -1;
  String? _cacheActor;
  final Map<String, Object?> _cache = {};

  // ---------------------------------------------------------------- lifecycle and identity

  /// Loads the device's log and metadata from [storage] and materializes state.
  static Future<Den> open({
    required DenStorage storage,
    required DeviceKeys keys,
    int Function()? now,
  }) async {
    final den = Den._(
      storage,
      keys,
      await keys.deviceId(),
      now ?? () => DateTime.now().toUtc().millisecondsSinceEpoch,
    );
    den._meta = {...?await storage.loadMeta()};
    den._loadMeta();
    den._pubkeys[den.deviceId] = keys.pubkey;
    final changes = await storage.loadChanges();
    changes.forEach(den._learnKey);
    den._mat.add(changes);
    den._observeApplied();
    var own = 0;
    for (final c in changes) {
      if (c.device != den.deviceId) continue;
      den._clock.observe(c.hlc);
      own = math.max(own, c.counter);
    }
    den._counter = math.max(den._counter, own);
    return den;
  }

  /// Keeps this device's clock past every valid change, so its next write is the newest. Invalid
  /// changes don't move it: a device nobody approved can't push the family's clocks ahead.
  void _observeApplied() {
    final applied = _mat.applied;
    if (applied.isNotEmpty) _clock.observe(applied.last.change.hlc);
  }

  /// Ends the [onChange] stream and the acting window's timer.
  Future<void> close() {
    _actingTimer?.cancel();
    _actingTimer = null;
    return _changes.close();
  }

  /// The engine's clock: UTC milliseconds now.
  int now() => _now();

  /// What [onChange] reports, besides record types, when who is acting changes or the acting
  /// window ends.
  static const String actingChanged = 'acting';

  final String deviceId;
  DeviceKeys get keys => _keys;
  String? get familyId => _root.familyId;
  bool get hasFamily => familyId != null;

  /// The founder's Ed25519 public key (base64url), which roots this family's trust.
  String? get founderPubkey => _root.founderPubkey;

  /// Whether this device's join request has been approved by a parent's device.
  bool get isApproved {
    final d = thisDevice;
    return d != null && d.approved && !d.revoked;
  }

  Device? get thisDevice => device(deviceId);

  /// The person this device belongs to: the owner of a personal device, or the parent whose
  /// device is running as the family's hub. Shared displays and hubs nobody owns have none.
  Member? get owner {
    final d = thisDevice;
    if (d == null || d.mode == DeviceMode.shared || d.member == null) return null;
    return member(d.member!);
  }

  /// Who changes are made as right now: the owner on a personal device; on a shared display, the
  /// member who verified within the acting window, else null (open check-off rules apply); on a
  /// hub, whoever an API or MCP call is acting as, else the hub's owner.
  Member? get actor {
    final d = thisDevice;
    if (d == null) return null;
    if (d.mode == DeviceMode.personal) return owner;
    if (actingUntil != null) return _actingMember == null ? null : member(_actingMember!);
    return d.mode == DeviceMode.hub ? owner : null;
  }

  /// UTC milliseconds when the acting window on a shared device ends, or null.
  int? get actingUntil {
    final until = _actingUntil;
    if (until == null || _now() >= until) return null;
    return until;
  }

  /// The API token or MCP connection label a hub records on its writes while acting, or null.
  String? get actingVia => actingUntil == null ? null : _actingVia;

  /// Sets who is acting on a shared device after [verifySignIn] succeeded; null ends it. On a hub,
  /// [via] names the API token or MCP connection making the calls, recorded as `_via` on every
  /// change in the window. On a personal device only its owner can act. [onChange] fires with
  /// [actingChanged] now and again when the window ends.
  void actAs(String? memberId, {Duration window = const Duration(seconds: 60), String? via}) {
    final d = thisDevice;
    if (d != null && d.mode == DeviceMode.personal) {
      if (memberId != null && memberId != d.member) {
        throw const PermissionDenied('A personal device acts only for its owner');
      }
      return;
    }
    if (memberId != null && member(memberId) == null) throw const InvalidInput('That person isn\'t in the family');
    if (memberId == null && via == null) {
      _endActing();
    } else {
      _actingMember = memberId;
      _actingVia = via;
      _actingUntil = _now() + window.inMilliseconds;
    }
    _scheduleActingTimer();
    _emit({actingChanged});
  }

  /// Times the end of the acting window, only while someone listens to [onChange], so an
  /// engine nobody watches leaves no timer behind.
  void _scheduleActingTimer() {
    _cancelActingTimer();
    final until = _actingUntil;
    if (until == null || _changes.isClosed || !_changes.hasListener) return;
    final left = until - _now();
    _actingTimer = Timer(Duration(milliseconds: left < 0 ? 0 : left), _actingWindowEnded);
  }

  void _cancelActingTimer() {
    _actingTimer?.cancel();
    _actingTimer = null;
  }

  void _endActing() {
    _actingMember = null;
    _actingUntil = null;
    _actingVia = null;
  }

  void _actingWindowEnded() {
    _actingTimer = null;
    if (actingUntil == null) _endActing();
    _emit({actingChanged});
  }

  /// Checks a PIN or picture pattern against the member's sign-in for shared screens. A parent
  /// with no sign-in never verifies on a shared display: anyone there could act as them.
  Future<bool> verifySignIn(String memberId, String secret) async {
    final m = member(memberId);
    if (m == null) return false;
    final signIn = m.signIn;
    if (signIn.kind == 'none') return !(m.isParent && thisDevice?.mode == DeviceMode.shared);
    if (signIn.salt == null || signIn.hash == null) return false;
    if (!signInSecretValid(signIn.kind, secret)) return false;
    return verifySignInHash(secret, signIn.salt!, signIn.hash!);
  }

  /// Writes the genesis changes: the family, the founding parent and this device, approved.
  Future<void> createFamily({
    required String familyName,
    required String timezone,
    required String yourName,
    required Marker marker,
    required Animal animal,
    required String deviceName,
    required DeviceKind deviceKind,
    DeviceMode mode = DeviceMode.personal,
  }) =>
      _locked(() async {
        if (hasFamily) throw StateError('This device already belongs to a family');
        if (!isKnownZone(timezone)) throw InvalidInput('Den doesn\'t know the time zone "$timezone"');
        final first = _clock.next();
        final id = familyIdFor(_keys.pubkey, first.millis);
        final memberId = newId();
        _setRoot(id, _keys.pubkey);
        for (final s in [Space.family, Space.parents, Space.member(memberId)]) {
          _keyring[s] = {0: [await _makeSpaceKey(s, 0)]};
        }
        try {
          await _commitNow([
            _Draft(RecordType.family, id, Space.family, {
              'name': familyName,
              'timezone': timezone,
              'weekStart': 0,
              'founderDevice': deviceId,
              'capture': 'direct',
              'pointsEnabled': true,
              'oversight': <String, Object?>{},
            }, hlc: first, actor: memberId, setsActor: true),
            _Draft(RecordType.member, memberId, Space.family, {
              'name': yourName,
              'role': Role.parent.name,
              'tier': null,
              'marker': marker.name,
              'animal': animal.name,
              'birthday': null,
              'grants': <String>[],
              'signIn': {'kind': 'none', 'salt': null, 'hash': null},
              'order': 0,
            }, actor: memberId, setsActor: true),
            _Draft(RecordType.device, deviceId, Space.family, {
              'name': deviceName,
              'kind': deviceKind.name,
              'pubkey': _keys.pubkey,
              'xpub': _keys.xpub,
              'member': memberId,
              'mode': mode.name,
              'approved': true,
              'approvedBy': memberId,
              'revoked': false,
              if (mode == DeviceMode.shared) 'display': _defaultDisplay,
            }, actor: memberId, setsActor: true),
          ]);
        } on Object {
          _meta.remove('familyId');
          _meta.remove('founderPubkey');
          _root = TrustRoot();
          _keyring.clear();
          rethrow;
        }
      });

  /// Records the family this device is joining and writes its own unapproved device record.
  /// [founderPubkey] comes from the QR code or the pairing session and roots trust.
  Future<void> requestJoin({
    required String familyId,
    required String founderPubkey,
    required String deviceName,
    required DeviceKind kind,
    DeviceMode mode = DeviceMode.personal,
    String? memberId,
  }) =>
      _locked(() async {
        if (hasFamily) throw StateError('This device already belongs to a family');
        if (deviceIdOf(founderPubkey) == null) throw const InvalidInput('The founder key isn\'t valid');
        _setRoot(familyId, founderPubkey);
        _mat.replay();
        await _commitNow([
          _Draft(RecordType.device, deviceId, Space.family, {
            'name': deviceName,
            'kind': kind.name,
            'pubkey': _keys.pubkey,
            'xpub': _keys.xpub,
            'member': memberId,
            'mode': mode.name,
            'approved': false,
          }, setsActor: true),
        ]);
      });

  /// Forgets the family on this device: wipes its log and metadata from storage and returns the
  /// engine to a fresh device's state, so a declined device or one the family no longer uses can
  /// start over. A family remembers devices it declined or removed, so join again with new keys.
  Future<void> leaveFamily() => _locked(() async {
        await _storage.clear();
        _actingTimer?.cancel();
        _actingTimer = null;
        _endActing();
        _root = TrustRoot();
        _meta = {};
        _floor.clear();
        _pending.clear();
        _keyring.clear();
        _pendingKeys.clear();
        _pubkeys
          ..clear()
          ..[deviceId] = _keys.pubkey;
        _mat.clear();
        _cache.clear();
        _cacheVersion = -1;
        await _saveMeta();
        _emit({...RecordType.all, actingChanged});
      });

  /// Fires with the record types that changed after every local write or ingest, and with
  /// [actingChanged] when who is acting changes.
  Stream<Set<String>> get onChange => _changes.stream;

  // ---------------------------------------------------------------- family state

  Family? get family {
    final id = familyId;
    if (id == null) return null;
    final e = _mat.store.liveAt(Space.family, RecordType.family, id);
    return e == null ? null : Family(e.rec);
  }

  String get _zone => family?.timezone ?? 'UTC';
  int get _weekStart => family?.weekStart ?? 0;

  /// Members in display order, removed members excluded.
  List<Member> get members => _memo('members', () {
        final list = [
          for (final e in _mat.store.liveOfType(RecordType.member))
            if (e.space == Space.family) Member(e.rec),
        ];
        list.sort((a, b) {
          final o = a.order.compareTo(b.order);
          if (o != 0) return o;
          final n = a.name.compareTo(b.name);
          return n != 0 ? n : a.id.compareTo(b.id);
        });
        return list;
      });

  Member? member(String id) {
    final e = _mat.store.liveAt(Space.family, RecordType.member, id);
    return e == null ? null : Member(e.rec);
  }

  List<Device> get devices => _memo('devices', () {
        return [
          for (final e in _mat.store.liveOfType(RecordType.device))
            if (e.space == Space.family) Device(e.rec),
        ]..sort((a, b) {
            final n = a.name.compareTo(b.name);
            return n != 0 ? n : a.id.compareTo(b.id);
          });
      });

  Device? device(String id) {
    final e = _mat.store.liveAt(Space.family, RecordType.device, id);
    return e == null ? null : Device(e.rec);
  }

  /// Devices waiting for a parent's approval.
  List<Device> get pendingDevices => devices.where((d) => !d.approved && !d.revoked).toList();

  List<EventCategory> get categories => _memo('categories', () {
        return [
          for (final e in _mat.store.liveOfType(RecordType.category))
            if (e.space == Space.family) EventCategory(e.rec),
        ]..sort((a, b) => a.name.compareTo(b.name));
      });

  EventCategory? category(String id) {
    final e = _mat.store.liveAt(Space.family, RecordType.category, id);
    return e == null ? null : EventCategory(e.rec);
  }

  /// Today's local date in the family's time zone, `YYYY-MM-DD`.
  String todayDate() => dateIn(_zone, _now());

  /// The local date of a UTC instant in the family's time zone.
  String dateOf(int utcMillis) => dateIn(_zone, utcMillis);

  /// UTC milliseconds of local midnight starting [date] in the family's time zone.
  int dayStart(String date) => dayStartIn(_zone, date);

  /// The spaces whose records the current actor on this device may see: what the device holds,
  /// narrowed to what the acting member may read.
  Set<String> get readableSpaces {
    if (!isApproved) return const {};
    final held = spacesForDevice(deviceId);
    final a = actor;
    if (a == null) return held;
    final f = family;
    return {for (final s in held) if (canRead(a, s, f)) s};
  }

  Future<void> updateFamily(Map<String, Object?> patch) async {
    final id = familyId;
    if (id == null || family == null) throw const InvalidInput('There is no family yet');
    final fields = _cleanPatch(patch, {
      'name', 'timezone', 'weekStart', 'capture', 'pointsEnabled', 'oversight', 'assistant',
      // One person's entry, `oversight.<memberId>`, so parents changing different people merge.
      for (final k in patch.keys) if (k.startsWith('oversight.')) k,
    });
    final tz = fields['timezone'];
    if (tz is String && !isKnownZone(tz)) throw InvalidInput('Den doesn\'t know the time zone "$tz"');
    await _commit([_Draft(RecordType.family, id, Space.family, fields)]);
  }

  Future<String> addMember({
    required String name,
    required Role role,
    Tier? tier,
    Marker marker = Marker.blue,
    Animal animal = Animal.cat,
    String? birthday,
    Set<Grant> grants = const {},
  }) async {
    final id = newId();
    final order = members.isEmpty ? 0 : members.map((m) => m.order).reduce(math.max) + 1;
    await _commit([
      _Draft(RecordType.member, id, Space.family, {
        'name': name,
        'role': role.name,
        'tier': tier?.name,
        'marker': marker.name,
        'animal': animal.name,
        'birthday': birthday,
        'grants': [for (final g in Grant.values) if (grants.contains(g)) g.name],
        'signIn': {'kind': 'none', 'salt': null, 'hash': null},
        'order': order,
      }),
    ]);
    await _locked(() => _rotateNow({Space.member(id)}));
    return id;
  }

  Future<void> updateMember(String id, Map<String, Object?> patch) async {
    if (member(id) == null) throw const InvalidInput('That person isn\'t in the family');
    final fields = _cleanPatch(patch, {'name', 'role', 'tier', 'marker', 'animal', 'birthday', 'grants', 'order'});
    final grants = fields['grants'];
    if (grants is Iterable) fields['grants'] = [for (final g in grants) g is Enum ? g.name : g];
    await _commit([_Draft(RecordType.member, id, Space.family, fields)]);
  }

  /// Removes a member and revokes the devices they own, rotating the keys of the spaces those
  /// devices held.
  Future<void> removeMember(String id) => _locked(() async {
        if (member(id) == null) throw const InvalidInput('That person isn\'t in the family');
        final owned = [
          for (final d in devices)
            if (d.member == id && d.id != deviceId && !d.revoked) d.id,
        ];
        final held = {for (final d in owned) ...spacesForDevice(d)};
        await _commitNow([
          for (final d in owned) _revocation(d),
          _Draft(RecordType.member, id, Space.family, {'_deleted': true}),
        ]);
        await _rotateNow(held);
      });

  /// Sets how a member signs in on shared screens: `pin` (4 digits), `pattern` (4 animals as
  /// digits 0-8), or `none`. Secrets are salted and hashed before they're written.
  Future<void> setSignIn(String memberId, {required String kind, String? secret}) async {
    if (member(memberId) == null) throw const InvalidInput('That person isn\'t in the family');
    if (!signInSecretValid(kind, secret)) {
      throw InvalidInput(kind == 'pin'
          ? 'A PIN is 4 digits'
          : kind == 'pattern'
              ? 'A picture pattern is 4 animals'
              : 'Sign-in must be a PIN, a picture pattern, or none');
    }
    final a = actor;
    if (a == null || (a.id != memberId && !can(a, DenAction.manageFamily))) {
      throw const PermissionDenied('Only parents can set someone else\'s sign-in');
    }
    final value = await hashSignIn(kind, secret);
    await _commit([_Draft(RecordType.member, memberId, Space.family, {'signIn': value})]);
  }

  Future<void> approveDevice(String deviceId, {String? member, DeviceMode? mode}) async {
    final d = device(deviceId);
    if (d == null) throw const InvalidInput('That device hasn\'t asked to join');
    final owner = member ?? d.member;
    final newMode = mode ?? d.mode;
    if (newMode == DeviceMode.personal && (owner == null || this.member(owner) == null)) {
      throw const InvalidInput('Choose whose device this is');
    }
    await _commit([
      _Draft(RecordType.device, deviceId, Space.family, {
        'approved': true,
        'approvedBy': actor?.id,
        if (d.revoked) 'revoked': false,
        'member': newMode == DeviceMode.personal ? owner : member,
        'mode': newMode.name,
        if (newMode == DeviceMode.shared && d.rec.fields['display'] == null) 'display': _defaultDisplay,
      }),
    ]);
  }

  /// Revokes a device. Revoking another device also rotates the keys of every space it held
  /// (a new random key, one epoch on), so it can't read what the family writes next.
  ///
  /// The revocation records the last of the device's changes this one holds (`revokedAfter`):
  /// anything it signs after that counts for nothing, whatever clock it claims.
  Future<void> revokeDevice(String deviceId) => _locked(() async {
        if (device(deviceId) == null) throw const InvalidInput('That device isn\'t in the family');
        final held = deviceId == this.deviceId ? const <String>{} : spacesForDevice(deviceId);
        await _commitNow([_revocation(deviceId)]);
        await _rotateNow(held);
      });

  /// Revokes [device], naming the last of its changes this device holds: its counters held here,
  /// and those a peer vouched for in spaces this device doesn't receive. Runs inside the lock,
  /// so nothing arrives between counting and signing.
  _Draft _revocation(String device) {
    var last = device == deviceId ? _counter : _floor[device] ?? 0;
    for (final n in _mat.counters[device] ?? const <int>{}) {
      if (n > last) last = n;
    }
    return _Draft(RecordType.device, device, Space.family, {'revoked': true, 'revokedAfter': last});
  }

  /// Changes another device's settings (parents), or this device's own name, display settings or
  /// mode (a parent acting on it).
  Future<void> updateDevice(String deviceId, Map<String, Object?> patch) async {
    if (device(deviceId) == null) throw const InvalidInput('That device isn\'t in the family');
    final fields = _cleanPatch(patch, {'name', 'kind', 'member', 'mode', 'display', 'xpub'});
    await _commit([_Draft(RecordType.device, deviceId, Space.family, fields)]);
  }

  /// Changes what this device is for: someone's own device, a shared display, or the family's
  /// hub ("Keep the family online"). A parent must be acting on it: its owner on a personal
  /// device, or a parent who verified on a shared one.
  Future<void> setThisDeviceMode(DeviceMode mode) async {
    final d = thisDevice;
    if (d == null || !isApproved) throw const InvalidInput('This device isn\'t part of a family yet');
    if (d.mode == mode) return;
    if (mode == DeviceMode.personal && d.member == null) {
      throw const InvalidInput('A personal device needs an owner; a parent sets one from their device');
    }
    await _commit([
      _Draft(RecordType.device, deviceId, Space.family, {
        'mode': mode.name,
        if (mode == DeviceMode.shared && d.rec.fields['display'] == null) 'display': _defaultDisplay,
      }),
    ]);
  }

  static const Map<String, Object?> _defaultDisplay = {'layout': 'week', 'openCheckoff': false};

  Future<String> addCategory({required String name, String icon = 'calendar'}) async {
    final id = newId();
    await _commit([_Draft(RecordType.category, id, Space.family, {'name': name, 'icon': icon})]);
    return id;
  }

  Future<void> updateCategory(String id, Map<String, Object?> patch) async {
    if (category(id) == null) throw const InvalidInput('That category doesn\'t exist');
    await _commit([_Draft(RecordType.category, id, Space.family, _cleanPatch(patch, {'name', 'icon'}))]);
  }

  Future<void> deleteCategory(String id) async {
    if (category(id) == null) throw const InvalidInput('That category doesn\'t exist');
    await _commit([_Draft(RecordType.category, id, Space.family, {'_deleted': true})]);
  }

  /// Undoes a removal: the record comes back exactly as it was, with whatever belonged to it (an
  /// event's changed occurrences, a list's items, a chore's completions). Needs the same
  /// permission as editing it.
  Future<void> restore(String type, String id) => restoreAll(type, [id]);

  /// [restore] for several records of one type, in one commit: the items "Clear done" removed.
  Future<void> restoreAll(String type, Iterable<String> ids) async {
    final drafts = <_Draft>[];
    for (final id in ids) {
      final e = _mat.store.find(type, id);
      if (e == null || !readableSpaces.contains(e.space)) throw const InvalidInput('That doesn\'t exist');
      if (e.deleted) drafts.add(_Draft(type, id, e.space, {'_deleted': false}));
    }
    await _commit(drafts);
  }

  // ---------------------------------------------------------------- recording, undo and previews

  /// The zone value [recording] keeps its lists of change ids under.
  static final Object _recorders = Object();

  /// The zone value [attributed] keeps its origin under.
  static final Object _origins = Object();

  /// Runs [body] with every change this device commits from its zone marked as coming from
  /// [origin] (`_from`, which History shows): what the in-app assistant changes while someone
  /// talks to it reads "from the assistant". A removal carries no `_from`, and a change that
  /// names its own origin keeps it.
  Future<T> attributed<T>(CaptureOrigin origin, FutureOr<T> Function() body) =>
      runZoned(() => Future<T>.sync(body), zoneValues: {_origins: origin});

  /// Runs [body] and returns what it returned with the ids of the changes this device committed
  /// while it ran: the changes an action made, for its receipt. Only writes made from [body]'s own
  /// zone count, not writes other callers make meanwhile. Recordings nest; an outer one also sees
  /// what an inner one recorded.
  ///
  /// With [undoOnError], a body that throws after writing has what it wrote taken back ([undo])
  /// before the error is passed on, so an action that fails half way leaves nothing behind.
  Future<Recorded<T>> recording<T>(FutureOr<T> Function() body, {bool undoOnError = false}) async {
    final ids = <String>[];
    final outer = Zone.current[_recorders];
    final sinks = <List<String>>[if (outer is List<List<String>>) ...outer, ids];
    try {
      final value = await runZoned(() => Future<T>.sync(body), zoneValues: {_recorders: sinks});
      return Recorded(value, List.unmodifiable(ids));
    } on Object {
      if (undoOnError && ids.isNotEmpty) {
        try {
          await undo(ids);
        } on Object {
          // The body's error is the one to report.
        }
      }
      rethrow;
    }
  }

  /// Takes back the changes [changeIds] names, field by field, as the actor and with the
  /// permission each change back needs (refused as a whole, with [PermissionDenied], when one
  /// isn't allowed):
  ///
  /// - a record they made is removed (and can be restored again);
  /// - a record they removed comes back as it was ([restore]);
  /// - a field they changed gets its old value back, one entry of a map field (`steps.<id>`,
  ///   `patch.<field>`) at a time;
  /// - points given or taken get a new adjustment the other way, since adjustments never change.
  ///
  /// What it leaves alone is reported in [UndoResult.skipped]: fields someone changed since
  /// (theirs is newer), a record someone removed or restored since, and what Den can't take
  /// back: adding or removing a person (removal revokes their devices and rotates keys), device
  /// and AI-access changes, and asking for a reward.
  Future<UndoResult> undo(Iterable<String> changeIds) => _locked(() async {
        final plan = _planUndo(changeIds);
        final made = await _commitNow(plan.drafts);
        return UndoResult(changes: [for (final c in made) c.id], skipped: plan.skipped);
      });

  /// Whether [undo] would write anything back for [changeIds] now. It may still be refused.
  bool canUndo(Iterable<String> changeIds) {
    try {
      return _planUndo(changeIds).drafts.isNotEmpty;
    } on InvalidInput {
      return false;
    }
  }

  /// A copy of this engine in memory, with the same log, keys and acting member, to try a change
  /// on before making it (a preview). What it writes is never stored or sent: don't sync it.
  /// Close it when done.
  Future<Den> fork() async {
    final storage = MemoryStorage();
    await storage.appendChanges(List.of(_mat.log));
    await storage.saveMeta({
      ..._meta,
      'counter': _counter,
      'floor': Map<String, Object?>.of(_floor),
      'spaceKeys': _keyringJson(),
    });
    final copy = await Den.open(storage: storage, keys: _keys, now: _now);
    copy
      .._actingMember = _actingMember
      .._actingUntil = _actingUntil
      .._actingVia = _actingVia;
    return copy;
  }

  static const String _trustRecords = 'Devices and AI access change only on a parent\'s own device';

  /// What a field that was never set means, for fields an undo may have to write back that way
  /// and whose schema takes no null. Other such fields are left as they are: without the rest
  /// of the record's changes taken back they mean nothing (what a step was worth when checked).
  static const Map<String, Object?> _unsetValues = {
    'completion.done': false,
    'eventException.cancelled': false,
    'item.checked': false,
    'item.toGroceries': false,
    'event.allDay': false,
    'event.countdown': false,
    'list.pinned': false,
    'subscription.skipAllDay': false,
    'chore.active': true,
    'reward.active': true,
    'reward.needsApproval': true,
    'family.pointsEnabled': true,
  };

  /// Whether [c] wrote [field]: the field itself, any entry of it when it's a map, or the whole
  /// map when [field] is one entry.
  static bool _touches(Change c, String field) {
    final dot = field.indexOf('.');
    for (final k in c.fields.keys) {
      if (k == field) return true;
      if (dot > 0 && k == field.substring(0, dot)) return true;
      if (dot < 0 && k.startsWith('$field.')) return true;
    }
    return false;
  }

  /// Whether the actor may remove a completion, which needs completing anyone's chores.
  bool get _mayRemoveCompletions {
    final a = actor;
    return a == null || can(a, DenAction.completeAnyChore);
  }

  /// A completion back to nothing done, for someone who may not remove it; null when it records
  /// a swap, which only a removal takes back.
  static Map<String, Object?>? _completionReset(Entry e) {
    if (e.fields.containsKey('owner')) return null;
    final steps = e.fields['steps'];
    return {
      if (e.fields['done'] == true || e.fields['doneBy'] != null) ...{'done': false, 'doneBy': null},
      if (steps is Map)
        for (final s in steps.entries)
          if (s.value != null) 'steps.${s.key}': null,
    };
  }

  /// Who has a chore on a completion's day before any swap.
  String? _scheduledOwnerOf(Entry completion) {
    final chore = _mat.store.at(completion.space, RecordType.chore, '${completion.fields['chore']}');
    final date = completion.fields['date'];
    if (chore == null || date is! String) return null;
    return scheduledOwner(Chore(chore.rec), date, _weekStart);
  }

  static String _undoReason(String reason) {
    final text = reason.trim().isEmpty ? 'Undo' : 'Undo: ${reason.trim()}';
    return text.length > maxTitle ? text.substring(0, maxTitle) : text;
  }

  /// The drafts [undo] writes for [changeIds], newest record first, and what it leaves alone.
  _UndoPlan _planUndo(Iterable<String> changeIds) {
    final want = <String>{};
    for (final id in changeIds) {
      if (!_mat.contains(id)) throw const InvalidInput('Den doesn\'t know that change');
      if (!_mat.rejected.containsKey(id)) want.add(id);
    }
    final drafts = <_Draft>[];
    final skipped = <UndoSkip>[];
    if (want.isEmpty) return _UndoPlan(drafts, skipped);
    // Walk back from the newest valid change until every one to undo is found; the others met on
    // the way came after the first of them.
    final ours = <Applied>[];
    final others = <Applied>[];
    final applied = _mat.applied;
    for (var i = applied.length - 1; i >= 0 && want.isNotEmpty; i--) {
      final a = applied[i];
      if (want.remove(a.change.id)) {
        ours.add(a);
      } else {
        others.add(a);
      }
    }
    String keyOf(Change c) => '${c.space}\u0000${c.type}\u0000${c.rid}';
    // Record -> the changes to undo that touched it, oldest first.
    final records = <String, List<Applied>>{};
    for (final a in ours.reversed) {
      (records[keyOf(a.change)] ??= []).add(a);
    }
    // Record -> later changes by anyone else, newest first.
    final since = <String, List<Applied>>{};
    for (final a in others) {
      final k = keyOf(a.change);
      if (records.containsKey(k)) (since[k] ??= []).add(a);
    }
    final readable = readableSpaces;
    final me = actor;
    // What was made last is taken back first: items before their list.
    for (final k in records.keys.toList().reversed) {
      final list = records[k]!;
      final first = list.first;
      final c0 = first.change;
      final type = c0.type;
      final entry = _mat.store.at(c0.space, type, c0.rid);
      if (entry == null) continue;
      if (!readable.contains(c0.space)) throw const InvalidInput('That doesn\'t exist');
      final title = titleOf(entry, _mat.store);
      UndoSkip skip(String reason, [String? field]) =>
          UndoSkip(type: type, id: c0.rid, title: title, reason: reason, field: field);
      _Draft draft(Map<String, Object?> fields) => _Draft(type, c0.rid, c0.space, fields);

      if (type == RecordType.device || type == RecordType.connection) {
        skipped.add(skip(_trustRecords));
        continue;
      }
      if (type == RecordType.member && list.any((a) => a.created || a.change.fields.containsKey('_deleted'))) {
        skipped.add(skip(first.created
            ? 'Den can\'t take back adding someone; a parent can remove them in the app'
            : 'Den can\'t bring back someone who was removed, since their devices were too; a parent can add them again'));
        continue;
      }
      if (type == RecordType.redemption && first.created) {
        skipped.add(skip('Asking for a reward can\'t be taken back; a parent can decline it'));
        continue;
      }
      if (type == RecordType.adjustment) {
        if (first.created) {
          final adjustment = Adjustment(entry.rec);
          drafts.add(_Draft(RecordType.adjustment, newId(), Space.family, {
            'member': adjustment.member,
            'delta': -adjustment.delta,
            'reason': _undoReason(adjustment.reason),
            'by': me?.id,
          }));
        }
        continue;
      }
      if (first.created) {
        if (entry.deleted) continue;
        if (type == RecordType.completion && !_mayRemoveCompletions) {
          final reset = _completionReset(entry);
          if (reset == null) {
            skipped.add(skip('${me?.name ?? 'This screen'} can\'t take back a swap; a parent can'));
          } else if (reset.isNotEmpty) {
            drafts.add(draft(reset));
          }
          continue;
        }
        drafts.add(draft({'_deleted': true}));
        continue;
      }

      final later = since[k] ?? const <Applied>[];
      if (later.any((o) => o.change.fields.containsKey('_deleted'))) {
        skipped.add(skip(entry.deleted ? 'It was removed since' : 'It was removed and put back since'));
        continue;
      }
      final firstTouch = <String, Applied>{};
      for (final a in list) {
        for (final f in a.change.fields.keys) {
          if (f != '_via' && f != '_from') firstTouch.putIfAbsent(f, () => a);
        }
      }
      final restore = <String, Object?>{};
      for (final e in firstTouch.entries) {
        final f = e.key;
        final at = e.value;
        final dot = f.indexOf('.');
        if (dot > 0) {
          // An entry written after its whole map: taking the map back covers it.
          final whole = firstTouch[f.substring(0, dot)];
          if (whole != null && changeOrder(whole.change, at.change) < 0) continue;
        }
        final newer = later.firstWhereOrNull((o) => o.change.hlc > at.change.hlc && _touches(o.change, f));
        if (newer != null) {
          skipped.add(skip('${_historyEntry(newer).actorName} changed it since', f));
          continue;
        }
        Object? value = copyJson(at.before[f]);
        if (value == null && at.absent.contains(f)) {
          final unset = '$type.$f';
          if (type == RecordType.completion && f == 'owner') {
            // A swap to anyone stores a null owner: unswapped is the owner the schedule gives.
            value = _scheduledOwnerOf(entry);
          } else if (_unsetValues.containsKey(unset)) {
            value = _unsetValues[unset];
          } else if (checkFields(type, {f: null}, creating: false) != null) {
            continue;
          }
        }
        restore[f] = value;
      }
      // An entry first written before its whole map goes into the map's old value.
      for (final f in [for (final key in restore.keys) if (key.indexOf('.') > 0) key]) {
        final dot = f.indexOf('.');
        final head = f.substring(0, dot);
        if (!restore.containsKey(head)) continue;
        final value = restore.remove(f);
        final whole = restore[head];
        if (whole is Map) {
          final merged = Map<String, Object?>.from(whole);
          if (value == null && firstTouch[f]!.absent.contains(f)) {
            merged.remove(f.substring(dot + 1));
          } else {
            merged[f.substring(dot + 1)] = value;
          }
          restore[head] = merged;
        }
      }
      if (firstTouch.containsKey('_deleted')) {
        final wasRemoved = restore.remove('_deleted') == true;
        if (wasRemoved) {
          // They restored it: put back what else they changed, then remove it again.
          if (restore.isNotEmpty) drafts.add(draft(restore));
          drafts.add(draft({'_deleted': true}));
        } else {
          drafts.add(draft({'_deleted': false, ...restore}));
        }
      } else if (restore.isNotEmpty) {
        drafts.add(draft(restore));
      }
    }
    return _UndoPlan(drafts, skipped);
  }

  // ---------------------------------------------------------------- calendar

  /// Live events the actor may see, by start.
  List<Event> get events => _memo('events', () {
        return [for (final e in _visibleLive(RecordType.event)) Event(e.rec)]
          ..sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : a.id.compareTo(b.id));
      });

  Map<String, Map<int, EventException>> get _exceptions => _memo('exceptions', () {
        final out = <String, Map<int, EventException>>{};
        for (final e in _visibleLive(RecordType.eventException)) {
          final x = EventException(e.rec);
          (out['${e.space}|${x.event}'] ??= {})[x.occurrence] = x;
        }
        return out;
      });

  Map<int, EventException> _exceptionsFor(Event e) => _exceptions['${e.space}|${e.id}'] ?? const {};

  /// Occurrences overlapping [start, end) (UTC ms), exceptions applied, sorted by start.
  List<Occurrence> occurrences(int start, int end) {
    final zoneName = _zone;
    final out = <Occurrence>[
      for (final e in events) ...occurrencesOf(e, _exceptionsFor(e), start, end, zoneName),
    ];
    out.sort(compareOccurrences);
    return out;
  }

  Event? event(String id) {
    final e = _visibleEntry(RecordType.event, id);
    return e == null ? null : Event(e.rec);
  }

  /// Adds an event and returns its id. [space], when given, places it in that space instead of
  /// [audience]'s (a hub writing into a member's private space, or importing a calendar feed).
  /// [source] marks an event that came from elsewhere, such as a subscribed calendar; it is
  /// manual by default.
  Future<String> addEvent({
    required String title,
    required int start,
    required int end,
    bool allDay = false,
    String? tz,
    String? rrule,
    List<String> assignees = const [],
    String? category,
    String location = '',
    String notes = '',
    List<int> reminders = const [],
    List<Ride> rides = const [],
    bool countdown = false,
    Audience audience = Audience.everyone,
    String? space,
    EventSource? source,
    CaptureOrigin? from,
  }) async {
    final id = newId();
    await _commit([
      _Draft(RecordType.event, id, space ?? _spaceFor(audience), {
        'title': title,
        'notes': notes,
        'location': location,
        'category': category,
        'start': start,
        'end': end,
        'allDay': allDay,
        'tz': tz ?? _zone,
        'rrule': _normalizeRule(rrule),
        'assignees': assignees,
        'reminders': reminders,
        'source': source == null || source.kind == 'manual'
            ? {'kind': 'manual'}
            : {'kind': source.kind, 'ref': source.ref, 'label': source.label},
        'rides': [for (final r in rides) {'leg': r.leg, 'driver': r.driver}],
        'countdown': countdown,
        '_from': ?from?.toJson(),
      }),
    ]);
    return id;
  }

  /// [occurrence] is the occurrence's series start, required for [EditScope.one] and
  /// [EditScope.following] on repeating events. A time change with [EditScope.all] shifts the
  /// whole series by the same wall-clock delta. An `audience` key ([Audience] or its name) moves
  /// the whole event to that audience's space, keeping its id.
  Future<void> updateEvent(
    String id,
    Map<String, Object?> patch, {
    EditScope scope = EditScope.all,
    int? occurrence,
  }) async {
    final entry = _requireLive(RecordType.event, id, 'That event doesn\'t exist');
    final event = Event(entry.rec);
    final fields = _cleanPatch(patch, {...eventFields.keys, 'audience'});
    final audience = fields.remove('audience');
    if (fields.containsKey('rrule')) fields['rrule'] = _normalizeRule(fields['rrule'] as String?);
    if (fields['rides'] is List) {
      fields['rides'] = [for (final r in fields['rides'] as List) r is Ride ? {'leg': r.leg, 'driver': r.driver} : r];
    }
    if (audience != null) {
      final target = _spaceFor(_audienceOf(audience));
      if (target != entry.space) {
        await _commit(_moveDrafts(entry, target, fields, RecordType.eventException, 'event'));
        return;
      }
    }
    if (fields.isEmpty) return;
    if (event.rrule == null || scope == EditScope.all) {
      await _commit(_seriesDrafts(entry, event, fields, occurrence));
      return;
    }
    if (occurrence == null) throw const InvalidInput('Choose which occurrence to change');
    if (!isSeriesStart(event, _zone, occurrence)) throw const InvalidInput('That isn\'t an occurrence of this event');
    if (scope == EditScope.one) {
      if (fields.keys.any((k) => !patchableEventFields.contains(k))) {
        throw const InvalidInput('That can only be changed for the whole series');
      }
      await _commit([
        _Draft(RecordType.eventException, '$id@$occurrence', entry.space, {
          'event': id,
          'occurrence': occurrence,
          'cancelled': false,
          for (final e in fields.entries) 'patch.${e.key}': e.value,
        }),
      ]);
      return;
    }
    if (occurrence == firstSeriesStart(event, _zone)) {
      await _commit(_seriesDrafts(entry, event, fields, occurrence));
      return;
    }
    await _commit(_splitDrafts(entry, event, fields, occurrence));
  }

  List<_Draft> _seriesDrafts(Entry entry, Event event, Map<String, Object?> fields, int? occurrence) {
    final drafts = <_Draft>[];
    final out = Map<String, Object?>.of(fields);
    final zoneName = eventZone(event, _zone);
    final repeating = event.rrule != null;
    if (fields['start'] is int) {
      final newStart = fields['start'] as int;
      final anchor = occurrence ?? event.start;
      final delta = wallDelta(zoneName, anchor, newStart);
      final seriesStart = repeating ? shiftWall(zoneName, event.start, delta) : newStart;
      final newEnd = fields['end'] is int ? fields['end'] as int : null;
      out['start'] = seriesStart;
      // The length people see, on the wall clock (or in days), carries over to the series start.
      out['end'] = newEnd == null
          ? occurrenceEnd(event, seriesStart, _zone)
          : seriesStart == newStart
              ? newEnd
              : shiftWall(zoneName, seriesStart, wallDelta(zoneName, newStart, newEnd));
      if (repeating && delta != Duration.zero) {
        for (final x in _exceptionsFor(event).values) {
          final moved = shiftWall(zoneName, x.occurrence, delta);
          if (moved == x.occurrence) continue;
          drafts
            ..add(_Draft(RecordType.eventException, x.id, entry.space, {'_deleted': true}))
            ..add(_Draft(RecordType.eventException, '${event.id}@$moved', entry.space, {
              'event': event.id,
              'occurrence': moved,
              'cancelled': x.cancelled,
              'patch': x.patch,
            }));
        }
      }
    } else if (fields['end'] is int && repeating && occurrence != null) {
      out['end'] = shiftWall(zoneName, event.start, wallDelta(zoneName, occurrence, fields['end'] as int));
    }
    return [_Draft(RecordType.event, event.id, entry.space, out), ...drafts];
  }

  List<_Draft> _splitDrafts(Entry entry, Event event, Map<String, Object?> fields, int occurrence) {
    final rule = ruleOf(event)!;
    final zoneName = eventZone(event, _zone);
    final before = countBefore(event, _zone, occurrence);
    final oldRule = rule.count != null ? rule.copyWith(count: () => before) : rule.endingBefore(occurrence);
    final newRule = rule.count != null ? rule.copyWith(count: () => rule.count! - before) : rule;
    final nextId = newId();
    final newStart = fields['start'] is int ? fields['start'] as int : occurrence;
    final newEnd = fields['end'] is int ? fields['end'] as int : occurrenceEnd(event, newStart, _zone);
    final next = <String, Object?>{
      for (final k in eventFields.keys)
        if (entry.fields.containsKey(k)) k: entry.fields[k],
      ...fields,
      'start': newStart,
      'end': newEnd,
      'rrule': fields.containsKey('rrule') ? fields['rrule'] : newRule.toString(),
    };
    final drafts = [
      _Draft(RecordType.event, event.id, entry.space, {'rrule': oldRule.toString()}),
      _Draft(RecordType.event, nextId, entry.space, next),
    ];
    final delta = wallDelta(zoneName, occurrence, newStart);
    for (final x in _exceptionsFor(event).values) {
      if (x.occurrence < occurrence) continue;
      final moved = delta == Duration.zero ? x.occurrence : shiftWall(zoneName, x.occurrence, delta);
      drafts
        ..add(_Draft(RecordType.eventException, x.id, entry.space, {'_deleted': true}))
        ..add(_Draft(RecordType.eventException, '$nextId@$moved', entry.space, {
          'event': nextId,
          'occurrence': moved,
          'cancelled': x.cancelled,
          'patch': x.patch,
        }));
    }
    return drafts;
  }

  Future<void> deleteEvent(String id, {EditScope scope = EditScope.all, int? occurrence}) async {
    final entry = _requireLive(RecordType.event, id, 'That event doesn\'t exist');
    final event = Event(entry.rec);
    List<_Draft> all() => [_Draft(RecordType.event, id, entry.space, {'_deleted': true})];
    if (event.rrule == null || scope == EditScope.all) {
      await _commit(all());
      return;
    }
    if (occurrence == null) throw const InvalidInput('Choose which occurrence to remove');
    if (!isSeriesStart(event, _zone, occurrence)) throw const InvalidInput('That isn\'t an occurrence of this event');
    if (scope == EditScope.one) {
      await _commit([
        _Draft(RecordType.eventException, '$id@$occurrence', entry.space, {
          'event': id,
          'occurrence': occurrence,
          'cancelled': true,
        }),
      ]);
      return;
    }
    if (occurrence == firstSeriesStart(event, _zone)) {
      await _commit(all());
      return;
    }
    final rule = ruleOf(event)!;
    final truncated = rule.count != null
        ? rule.copyWith(count: () => countBefore(event, _zone, occurrence))
        : rule.endingBefore(occurrence);
    await _commit([
      _Draft(RecordType.event, id, entry.space, {'rrule': truncated.toString()}),
      for (final x in _exceptionsFor(event).values)
        if (x.occurrence >= occurrence) _Draft(RecordType.eventException, x.id, entry.space, {'_deleted': true}),
    ]);
  }

  /// Undoes [deleteEvent] with the same [scope] and [occurrence], in one commit: the event with
  /// its changed occurrences, the one occurrence, or every occurrence from [occurrence] on, where
  /// [rrule] is the repeat rule the series had before.
  Future<void> restoreEvent(String id, {EditScope scope = EditScope.all, int? occurrence, String? rrule}) async {
    final entry = _mat.store.find(RecordType.event, id);
    if (entry == null || !readableSpaces.contains(entry.space)) throw const InvalidInput('That event doesn\'t exist');
    if (entry.deleted || scope == EditScope.all) {
      await restore(RecordType.event, id);
      return;
    }
    if (occurrence == null) throw const InvalidInput('Choose which occurrence to put back');
    final exceptions = [
      for (final x in _mat.store.ofType(RecordType.eventException))
        if (x.space == entry.space && x.fields['event'] == id) x,
    ];
    if (scope == EditScope.one) {
      final x = exceptions.firstWhereOrNull((x) => x.id == '$id@$occurrence' && !x.deleted);
      if (x == null || x.fields['cancelled'] != true) return;
      await _commit([_Draft(RecordType.eventException, x.id, entry.space, {'cancelled': false})]);
      return;
    }
    if (rrule == null) throw const InvalidInput('Choose how the event repeated');
    // The changed occurrences removed with the series' end: removed no earlier than its rule changed.
    final from = occurrence;
    final cut = entry.times['rrule'];
    bool removedWithEnd(Entry x) {
      final at = x.times['_deleted'];
      final when = x.fields['occurrence'];
      return x.deleted && cut != null && at != null && !(at < cut) && when is int && when >= from;
    }

    await _commit([
      _Draft(RecordType.event, id, entry.space, {'rrule': _normalizeRule(rrule)}),
      for (final x in exceptions)
        if (removedWithEnd(x)) _Draft(RecordType.eventException, x.id, entry.space, {'_deleted': false}),
    ]);
  }

  /// Sets the driver of a ride leg for one occurrence (null releases it).
  Future<void> claimRide(String eventId, {required int occurrence, required String leg, String? driver}) async {
    if (leg != 'to' && leg != 'from') throw const InvalidInput('A ride leg is "to" or "from"');
    if (driver != null && member(driver) == null) throw const InvalidInput('That person isn\'t in the family');
    final entry = _requireLive(RecordType.event, eventId, 'That event doesn\'t exist');
    final event = Event(entry.rec);
    if (event.rrule == null) {
      await _commit([
        _Draft(RecordType.event, eventId, entry.space, {'rides': ridesWith(event.rides, leg, driver)}),
      ]);
      return;
    }
    if (!isSeriesStart(event, _zone, occurrence)) throw const InvalidInput('That isn\'t an occurrence of this event');
    final xid = '$eventId@$occurrence';
    final existing = _mat.store.liveAt(entry.space, RecordType.eventException, xid);
    final x = existing == null ? null : EventException(existing.rec);
    final rides = buildOccurrence(event, occurrence, x, familyZone: _zone).rides;
    await _commit([
      _Draft(RecordType.eventException, xid, entry.space, {
        'event': eventId,
        'occurrence': occurrence,
        'patch.rides': ridesWith(rides, leg, driver),
      }),
    ]);
  }

  // ---------------------------------------------------------------- chores

  List<Chore> get chores => _memo('chores', () {
        return [for (final e in _visibleLive(RecordType.chore)) Chore(e.rec)]
          ..sort((a, b) {
            final t = a.title.compareTo(b.title);
            return t != 0 ? t : a.id.compareTo(b.id);
          });
      });

  Chore? chore(String id) {
    final e = _visibleEntry(RecordType.chore, id);
    return e == null ? null : Chore(e.rec);
  }

  Completion? _completionOf(Chore chore, String date) {
    final e = _mat.store.liveAt(chore.space, RecordType.completion, Completion.idFor(chore.id, date));
    return e == null ? null : Completion(e.rec);
  }

  /// Chores scheduled on [date] (local), plus earlier one-off chores still not done.
  List<ChoreDay> choresOn(String date) {
    final today = todayDate();
    final wall = wallTime(_zone, _now());
    final nowMinutes = wall.hour * 60 + wall.minute;
    ChoreDay dayOf(Chore c, String d) => choreDay(
          chore: c,
          date: d,
          completion: _completionOf(c, d),
          weekStart: _weekStart,
          today: today,
          nowMinutes: nowMinutes,
        );
    final out = <ChoreDay>[];
    for (final c in chores) {
      if (!c.active) continue;
      final once = c.schedule.once;
      if (once != null) {
        if (once == date) {
          out.add(dayOf(c, date));
        } else if (once.compareTo(date) < 0 && !isDone(c, _completionOf(c, once))) {
          out.add(dayOf(c, once));
        }
      } else if (scheduledOn(c, date)) {
        out.add(dayOf(c, date));
      }
    }
    final order = {for (final m in members) m.id: m.order};
    out.sort((a, b) {
      final oa = a.owner == null ? 1 << 30 : order[a.owner] ?? (1 << 29);
      final ob = b.owner == null ? 1 << 30 : order[b.owner] ?? (1 << 29);
      if (oa != ob) return oa.compareTo(ob);
      final da = a.chore.dueTime ?? '99:99', db = b.chore.dueTime ?? '99:99';
      if (da != db) return da.compareTo(db);
      final t = a.chore.title.compareTo(b.chore.title);
      return t != 0 ? t : a.chore.id.compareTo(b.chore.id);
    });
    return out;
  }

  /// Chores not done by their day, oldest first: every chore on the chart in the [days] days
  /// before today that wasn't done (a repeating one too, which [choresOn] doesn't carry over),
  /// one-off chores until they're done, and today's chores past their due time.
  List<ChoreDay> lateChores({int days = 2}) {
    final today = todayDate();
    final seen = <String>{};
    final out = <ChoreDay>[];
    for (var i = days; i >= 0; i--) {
      for (final cd in choresOn(addDays(today, -i))) {
        if (cd.late && seen.add('${cd.chore.id}@${cd.date}')) out.add(cd);
      }
    }
    mergeSort(out, compare: (a, b) => a.date.compareTo(b.date));
    return out;
  }

  /// Adds a chore and returns its id. [space], when given, places it in that space instead of
  /// [audience]'s.
  /// A chore's completions, by date, between [from] and [to] (local dates, both included).
  List<Completion> completionsFor(String choreId, {String? from, String? to}) {
    final c = _mat.store.find(RecordType.chore, choreId);
    if (c == null || !readableSpaces.contains(c.space)) return const [];
    return [
      for (final e in _mat.store.liveOfType(RecordType.completion))
        if (e.space == c.space &&
            e.fields['chore'] == choreId &&
            (from == null || (e.fields['date'] as String).compareTo(from) >= 0) &&
            (to == null || (e.fields['date'] as String).compareTo(to) <= 0))
          Completion(e.rec),
    ]..sort((a, b) => a.date.compareTo(b.date));
  }

  Future<String> addChore({
    required String title,
    required ChoreOwner owner,
    required ChoreSchedule schedule,
    String icon = 'check',
    String notes = '',
    String? dueTime,
    int points = 0,
    List<ChoreStep> steps = const [],
    List<int> reminders = const [],
    Audience audience = Audience.everyone,
    String? space,
    CaptureOrigin? from,
  }) async {
    final id = newId();
    await _commit([
      _Draft(RecordType.chore, id, space ?? _spaceFor(audience), {
        'title': title,
        'notes': notes,
        'icon': icon,
        'owner': owner.toJson(),
        'schedule': _scheduleJson(schedule),
        'dueTime': dueTime,
        'points': points,
        'steps': _stepsJson(steps),
        'reminders': reminders,
        'active': true,
        '_from': ?from?.toJson(),
      }),
    ]);
    return id;
  }

  Map<String, Object?> _scheduleJson(ChoreSchedule s) =>
      s.once != null ? {'once': s.once} : {'rrule': _normalizeRule(s.rrule), 'start': s.start};

  List<Map<String, Object?>> _stepsJson(List<ChoreStep> steps) => [
        for (final s in steps) {...s.toJson(), 'id': s.id.isEmpty ? newId().substring(0, 8) : s.id},
      ];

  /// An `audience` key moves the chore and its completions to that audience's space.
  Future<void> updateChore(String id, Map<String, Object?> patch) async {
    final entry = _requireLive(RecordType.chore, id, 'That chore doesn\'t exist');
    final fields = _cleanPatch(patch, {...typeSpecs[RecordType.chore]!.fields.keys, 'audience'});
    final audience = fields.remove('audience');
    if (fields['owner'] is ChoreOwner) fields['owner'] = (fields['owner'] as ChoreOwner).toJson();
    if (fields['schedule'] is ChoreSchedule) fields['schedule'] = _scheduleJson(fields['schedule'] as ChoreSchedule);
    if (fields['steps'] is List<ChoreStep>) fields['steps'] = _stepsJson(fields['steps'] as List<ChoreStep>);
    if (audience != null) {
      final target = _spaceFor(_audienceOf(audience));
      if (target != entry.space) {
        final after = {...entry.fields, ...fields};
        final prices = {
          for (final s in (after['steps'] as List?) ?? const <Object?>[])
            if (s is Map) '${s['id']}': (s['points'] as num?)?.toInt() ?? 0,
        };
        final price = (after['points'] as num?)?.toInt() ?? 0;
        final pricer = _mayPrice;
        await _commit([
          for (final d in _moveDrafts(entry, target, fields, RecordType.completion, 'chore'))
            d.type == RecordType.completion && d.space == target
                ? _Draft(d.type, d.rid, d.space, _movedCompletion(d.fields, price, prices, pricer: pricer))
                : d,
        ]);
        return;
      }
    }
    if (fields.isEmpty) return;
    await _commit([_Draft(RecordType.chore, id, entry.space, fields)]);
  }

  /// Whether the actor may set what chores are worth: a points manager, or a hub acting for a
  /// connection with no member.
  bool get _mayPrice {
    final a = actor;
    if (a == null) return thisDevice?.mode == DeviceMode.hub;
    return can(a, DenAction.managePoints);
  }

  /// A completion's fields as copied with its chore into another space: checks of steps the
  /// chore no longer has are left behind, and someone who doesn't set prices carries over what
  /// it was worth only up to what the chore is worth now.
  static Map<String, Object?> _movedCompletion(
    Map<String, Object?> fields,
    int price,
    Map<String, int> prices, {
    required bool pricer,
  }) {
    int capped(int v, int max) => pricer || v <= max ? v : max;
    final out = Map<String, Object?>.of(fields);
    final steps = out['steps'];
    if (steps is Map) {
      out['steps'] = {
        for (final e in steps.entries)
          if (prices.containsKey(e.key)) '${e.key}': e.value,
      };
    }
    final worth = out['stepPoints'];
    if (worth is Map) {
      out['stepPoints'] = {
        for (final e in worth.entries)
          if (prices.containsKey(e.key) && e.value is int) '${e.key}': capped(e.value as int, prices[e.key]!),
      };
    }
    final points = out['points'];
    if (points is int) out['points'] = capped(points, price);
    return out;
  }

  Future<void> deleteChore(String id) async {
    final entry = _requireLive(RecordType.chore, id, 'That chore doesn\'t exist');
    await _commit([_Draft(RecordType.chore, id, entry.space, {'_deleted': true})]);
  }

  /// Who gets credit for a step checked on a shared screen with nobody signed in.
  String _anonymousChecker(ChoreStep step, String? owner) => step.owner ?? owner ?? '';

  /// Marks the chore done or not done on [date]. Marking done also checks every step, keeping
  /// whoever already checked each one; marking not done clears them.
  Future<void> setChoreDone(String choreId, String date, bool done) =>
      setChoreDoneBy(choreId, date, done, actor?.id);

  /// [setChoreDone], crediting [doneBy] (null: nobody in particular) instead of the actor. Used
  /// when the actor records what someone else did, such as a hub token naming who did a chore;
  /// validation still decides whether the actor may complete it for them.
  Future<void> setChoreDoneBy(String choreId, String date, bool done, String? doneBy) async {
    if (!isLocalDate(date)) throw const InvalidInput('That isn\'t a date');
    if (doneBy != null && member(doneBy) == null) throw const InvalidInput('That person isn\'t in the family');
    final chore = _requireChore(choreId);
    final completion = _completionOf(chore, date);
    final me = doneBy;
    final owner = dayOwner(chore, date, completion, _weekStart);
    final checked = completion?.steps ?? const {};
    await _commit([
      _Draft(RecordType.completion, Completion.idFor(chore.id, date), chore.space, {
        'chore': chore.id,
        'date': date,
        'done': done,
        'doneBy': done ? me : null,
        if (done) 'points': chore.points,
        for (final s in chore.steps)
          if (done && checked[s.id] == null) ...{
            'steps.${s.id}': me ?? _anonymousChecker(s, owner),
            'stepPoints.${s.id}': s.points,
          } else if (!done && checked[s.id] != null)
            'steps.${s.id}': null,
      }),
    ]);
  }

  /// Checks or unchecks one step; checking the last one completes the chore, unchecking any
  /// step of a done chore reopens it.
  Future<void> setStep(String choreId, String date, String stepId, bool checked) =>
      setStepBy(choreId, date, stepId, checked, actor?.id);

  /// [setStep], crediting [checkedBy] (null: the step's owner, else the chore's owner that day)
  /// instead of the actor; validation still decides whether the actor may check it for them.
  Future<void> setStepBy(String choreId, String date, String stepId, bool checked, String? checkedBy) async {
    if (!isLocalDate(date)) throw const InvalidInput('That isn\'t a date');
    if (checkedBy != null && member(checkedBy) == null) throw const InvalidInput('That person isn\'t in the family');
    final chore = _requireChore(choreId);
    final step = chore.steps.firstWhereOrNull((s) => s.id == stepId);
    if (step == null) throw const InvalidInput('That chore has no such step');
    final completion = _completionOf(chore, date);
    final me = checkedBy;
    final owner = dayOwner(chore, date, completion, _weekStart);
    final value = checked ? (me ?? _anonymousChecker(step, owner)) : null;
    final after = {...?completion?.steps, stepId: value};
    final allChecked = chore.steps.every((s) => after[s.id] != null);
    final wasDone = isDone(chore, completion);
    await _commit([
      _Draft(RecordType.completion, Completion.idFor(chore.id, date), chore.space, {
        'chore': chore.id,
        'date': date,
        'steps.$stepId': value,
        if (checked) ...{'stepPoints.$stepId': step.points, 'points': chore.points},
        if (checked && allChecked && !wasDone) ...{'done': true, 'doneBy': me},
        if (!checked && wasDone) ...{'done': false, 'doneBy': null},
      }),
    ]);
  }

  /// Hands the chore to [toMember] for [date] only (null gives it to anyone).
  Future<void> swapForDay(String choreId, String date, String? toMember) async {
    if (!isLocalDate(date)) throw const InvalidInput('That isn\'t a date');
    if (toMember != null && member(toMember) == null) throw const InvalidInput('That person isn\'t in the family');
    final chore = _requireChore(choreId);
    await _commit([
      _Draft(RecordType.completion, Completion.idFor(chore.id, date), chore.space, {
        'chore': chore.id,
        'date': date,
        'owner': toMember,
      }),
    ]);
  }

  Chore _requireChore(String id) =>
      Chore(_requireLive(RecordType.chore, id, 'That chore doesn\'t exist').rec);

  // ---------------------------------------------------------------- lists

  /// Lists in display order with their items: pinned first, then by order.
  List<ListState> get lists => _memo('lists', () {
        final items = <String, List<Item>>{};
        for (final e in _visibleLive(RecordType.item)) {
          final item = Item(e.rec);
          (items['${e.space}|${item.list}'] ??= []).add(item);
        }
        final out = [
          for (final e in _visibleLive(RecordType.list))
            ListState(DenList(e.rec), (items['${e.space}|${e.id}'] ?? [])..sort(_compareItems)),
        ];
        out.sort((a, b) {
          if (a.list.pinned != b.list.pinned) return a.list.pinned ? -1 : 1;
          final o = a.list.order.compareTo(b.list.order);
          if (o != 0) return o;
          final t = a.list.title.compareTo(b.list.title);
          return t != 0 ? t : a.list.id.compareTo(b.list.id);
        });
        return out;
      });

  static int _compareItems(Item a, Item b) {
    final o = a.order.compareTo(b.order);
    if (o != 0) return o;
    final c = a.rec.created.compareTo(b.rec.created);
    return c != 0 ? c : a.id.compareTo(b.id);
  }

  ListState? list(String id) => lists.firstWhereOrNull((l) => l.list.id == id);

  /// Store names used on items, most used first.
  List<String> get stores {
    final counts = <String, int>{};
    final live = {for (final l in lists) '${l.list.space}|${l.list.id}'};
    for (final e in _visibleLive(RecordType.item)) {
      if (!live.contains('${e.space}|${e.fields['list']}')) continue;
      final store = (e.fields['store'] as String?)?.trim();
      if (store != null && store.isNotEmpty) counts.update(store, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts.keys.toList()
      ..sort((a, b) {
        final n = counts[b]!.compareTo(counts[a]!);
        return n != 0 ? n : a.compareTo(b);
      });
  }

  /// Adds a list and returns its id. [space], when given, places it in that space instead of
  /// [audience]'s.
  Future<String> addList({
    required String title,
    ListKind kind = ListKind.checklist,
    ListLifecycle lifecycle = ListLifecycle.running,
    String? needBy,
    String? event,
    String? icon,
    bool pinned = false,
    Audience audience = Audience.everyone,
    String? space,
    CaptureOrigin? from,
  }) async {
    final id = newId();
    final last = lists.map((l) => l.list.order).where(isOrderKey).maxOrNull;
    await _commit([
      _Draft(RecordType.list, id, space ?? _spaceFor(audience), {
        'title': title,
        'icon': icon ?? kind.name,
        'kind': kind.name,
        'lifecycle': lifecycle.name,
        'needBy': needBy,
        'event': event,
        'pinned': pinned,
        'order': keyBetween(last, null),
        '_from': ?from?.toJson(),
      }),
    ]);
    return id;
  }

  /// An `audience` key moves the list and its items to that audience's space.
  Future<void> updateList(String id, Map<String, Object?> patch) async {
    final entry = _requireLive(RecordType.list, id, 'That list doesn\'t exist');
    final fields = _cleanPatch(patch, {...typeSpecs[RecordType.list]!.fields.keys, 'audience'});
    final audience = fields.remove('audience');
    if (audience != null) {
      final target = _spaceFor(_audienceOf(audience));
      if (target != entry.space) {
        await _commit(_moveDrafts(entry, target, fields, RecordType.item, 'list'));
        return;
      }
    }
    if (fields.isEmpty) return;
    await _commit([_Draft(RecordType.list, id, entry.space, fields)]);
  }

  Future<void> deleteList(String id) async {
    final entry = _requireLive(RecordType.list, id, 'That list doesn\'t exist');
    await _commit([_Draft(RecordType.list, id, entry.space, {'_deleted': true})]);
  }

  /// Adds an item at the end. On a meal list, [toGroceries] also adds it to the first pinned
  /// shopping list. [from] records what a capture read to find it.
  Future<String> addItem(
    String listId, {
    required String text,
    String? qty,
    String? store,
    bool toGroceries = false,
    CaptureOrigin? from,
  }) async {
    final entry = _requireLive(RecordType.list, listId, 'That list doesn\'t exist');
    final target = DenList(entry.rec);
    final id = newId();
    final drafts = [
      _Draft(RecordType.item, id, entry.space, {
        'list': listId,
        'text': text,
        'qty': qty,
        'store': store,
        'checked': false,
        'checkedBy': null,
        'order': _endKey(listId),
        'toGroceries': toGroceries,
        '_from': ?from?.toJson(),
      }),
      if (toGroceries && target.kind == ListKind.meal) ..._mirrorDrafts(text, qty, store),
    ];
    await _commit(drafts);
    return id;
  }

  String _endKey(String listId) {
    final items = list(listId)?.items ?? const <Item>[];
    final last = items.map((i) => i.order).where(isOrderKey).maxOrNull;
    return keyBetween(last, null);
  }

  /// The first pinned shopping list, else the first shopping list.
  ListState? get _groceries {
    final shopping = lists.where((l) => l.list.kind == ListKind.shopping).toList();
    return shopping.firstWhereOrNull((l) => l.list.pinned) ?? shopping.firstOrNull;
  }

  List<_Draft> _mirrorDrafts(String text, String? qty, String? store) {
    final groceries = _groceries;
    if (groceries == null) return const [];
    final exists = groceries.items.any((i) => !i.checked && i.text.toLowerCase() == text.toLowerCase());
    if (exists) return const [];
    return [
      _Draft(RecordType.item, newId(), groceries.list.space, {
        'list': groceries.list.id,
        'text': text,
        'qty': qty,
        'store': store,
        'checked': false,
        'checkedBy': null,
        'order': _endKey(groceries.list.id),
        'toGroceries': false,
      }),
    ];
  }

  Future<void> updateItem(String id, Map<String, Object?> patch) async {
    final entry = _requireLive(RecordType.item, id, 'That item doesn\'t exist');
    final item = Item(entry.rec);
    final fields = _cleanPatch(patch, {'text', 'qty', 'store', 'checked', 'checkedBy', 'order', 'toGroceries'});
    if (fields.containsKey('checked') && !fields.containsKey('checkedBy')) {
      fields['checkedBy'] = fields['checked'] == true ? actor?.id : null;
    }
    final listEntry = _mat.store.liveAt(entry.space, RecordType.list, item.list);
    final mirror = fields['toGroceries'] == true &&
        !item.toGroceries &&
        listEntry != null &&
        DenList(listEntry.rec).kind == ListKind.meal;
    await _commit([
      _Draft(RecordType.item, id, entry.space, fields),
      if (mirror)
        ..._mirrorDrafts(
          (fields['text'] as String?) ?? item.text,
          fields.containsKey('qty') ? fields['qty'] as String? : item.qty,
          fields.containsKey('store') ? fields['store'] as String? : item.store,
        ),
    ]);
  }

  Future<void> setItemChecked(String id, bool checked) async {
    final entry = _requireLive(RecordType.item, id, 'That item doesn\'t exist');
    await _commit([
      _Draft(RecordType.item, id, entry.space, {'checked': checked, 'checkedBy': checked ? actor?.id : null}),
    ]);
  }

  Future<void> removeItem(String id) async {
    final entry = _requireLive(RecordType.item, id, 'That item doesn\'t exist');
    await _commit([_Draft(RecordType.item, id, entry.space, {'_deleted': true})]);
  }

  /// Removes every checked item from a list; returns how many.
  Future<int> clearChecked(String listId) async {
    _requireLive(RecordType.list, listId, 'That list doesn\'t exist');
    final checked = list(listId)!.items.where((i) => i.checked).toList();
    if (checked.isEmpty) return 0;
    await _commit([
      for (final i in checked) _Draft(RecordType.item, i.id, i.space, {'_deleted': true}),
    ]);
    return checked.length;
  }

  /// Moves an item between two neighbors (either may be null at the ends).
  Future<void> moveItem(String id, {String? after, String? before}) async {
    final entry = _requireLive(RecordType.item, id, 'That item doesn\'t exist');
    final item = Item(entry.rec);
    final items = list(item.list)?.items.where((i) => i.id != id).toList() ?? const <Item>[];
    final a = after == null ? null : items.firstWhereOrNull((i) => i.id == after);
    final b = before == null ? null : items.firstWhereOrNull((i) => i.id == before);
    if ((after != null && a == null) || (before != null && b == null)) {
      throw const InvalidInput('Those items aren\'t on the same list');
    }
    String? low = a?.order;
    String? high = b?.order;
    if (a != null && b == null) {
      final i = items.indexOf(a);
      high = items.skip(i + 1).map((x) => x.order).firstWhereOrNull((o) => o.compareTo(a.order) > 0);
    } else if (b != null && a == null) {
      final i = items.indexOf(b);
      low = items.take(i).map((x) => x.order).lastWhereOrNull((o) => o.compareTo(b.order) < 0);
    } else if (a != null && b != null && a.order.compareTo(b.order) >= 0) {
      final i = items.indexOf(a);
      high = items.skip(i + 1).map((x) => x.order).firstWhereOrNull((o) => o.compareTo(a.order) > 0);
    }
    await _commit([_Draft(RecordType.item, id, entry.space, {'order': keyBetween(low, high)})]);
  }

  // ---------------------------------------------------------------- points

  PointsInput _pointsInput() {
    final store = _mat.store;
    return PointsInput(
      members: members,
      completions: [for (final e in _visibleLive(RecordType.completion)) Completion(e.rec)],
      choreFor: (c) {
        final e = store.at(c.space, RecordType.chore, c.chore);
        return e == null ? null : Chore(e.rec);
      },
      adjustments: [for (final e in _visibleLive(RecordType.adjustment)) Adjustment(e.rec)],
      redemptions: [for (final e in _visibleLive(RecordType.redemption)) Redemption(e.rec)],
      rewards: [for (final e in _visibleLive(RecordType.reward)) Reward(e.rec)],
      goals: [for (final e in _visibleLive(RecordType.goal)) Goal(e.rec)],
      zone: _zone,
      weekStart: _weekStart,
      today: todayDate(),
    );
  }

  PointsSummary points() => pointsSummary(_pointsInput());

  /// Every reward the actor may see, retired ones too ([PointsSummary.rewards] has only those
  /// that can be asked for), cheapest first.
  List<Reward> get rewards => _memo('rewards', () {
        return [for (final e in _visibleLive(RecordType.reward)) Reward(e.rec)]
          ..sort((a, b) {
            final c = a.cost.compareTo(b.cost);
            return c != 0 ? c : a.title.compareTo(b.title);
          });
      });

  /// Every goal the actor may see, by title.
  List<Goal> get goals => _memo('goals', () {
        return [for (final e in _visibleLive(RecordType.goal)) Goal(e.rec)]..sort((a, b) => a.title.compareTo(b.title));
      });

  Future<void> adjustPoints(String memberId, int delta, String reason) async {
    if (member(memberId) == null) throw const InvalidInput('That person isn\'t in the family');
    await _commit([
      _Draft(RecordType.adjustment, newId(), Space.family, {
        'member': memberId,
        'delta': delta,
        'reason': reason,
        'by': actor?.id,
      }),
    ]);
  }

  Future<String> addGoal({
    required String title,
    required int target,
    GoalMode mode = GoalMode.target,
    List<String>? members,
    String? start,
    String? end,
    GoalRepeat repeat = GoalRepeat.none,
    String reward = '',
  }) async {
    final id = newId();
    await _commit([
      _Draft(RecordType.goal, id, Space.family, {
        'title': title,
        'mode': mode.name,
        'target': target,
        'members': members,
        'start': start ?? todayDate(),
        'end': end,
        'repeat': repeat.name,
        'reward': reward,
      }),
    ]);
    return id;
  }

  Future<void> updateGoal(String id, Map<String, Object?> patch) async {
    _requireLive(RecordType.goal, id, 'That goal doesn\'t exist');
    final fields = _cleanPatch(patch, typeSpecs[RecordType.goal]!.fields.keys.toSet());
    await _commit([_Draft(RecordType.goal, id, Space.family, fields)]);
  }

  Future<void> deleteGoal(String id) async {
    _requireLive(RecordType.goal, id, 'That goal doesn\'t exist');
    await _commit([_Draft(RecordType.goal, id, Space.family, {'_deleted': true})]);
  }

  Future<String> addReward({required String title, required int cost, String icon = 'gift', bool needsApproval = true}) async {
    final id = newId();
    await _commit([
      _Draft(RecordType.reward, id, Space.family, {
        'title': title,
        'cost': cost,
        'icon': icon,
        'needsApproval': needsApproval,
        'active': true,
      }),
    ]);
    return id;
  }

  Future<void> updateReward(String id, Map<String, Object?> patch) async {
    _requireLive(RecordType.reward, id, 'That reward doesn\'t exist');
    await _commit([
      _Draft(RecordType.reward, id, Space.family,
          _cleanPatch(patch, typeSpecs[RecordType.reward]!.fields.keys.toSet())),
    ]);
  }

  /// Asks to spend points on a reward for [member] (default: the actor). Rewards that don't
  /// need approval are approved at once. Refused when the balance, less what requests still
  /// waiting for a parent would spend, is short.
  Future<String> requestReward(String rewardId, {String? member}) async {
    final rewardEntry = _requireLive(RecordType.reward, rewardId, 'That reward doesn\'t exist');
    final reward = Reward(rewardEntry.rec);
    final who = member ?? actor?.id;
    if (who == null || this.member(who) == null) throw const InvalidInput('Choose who the reward is for');
    final summary = points();
    final available = summary.available(who);
    if (available < reward.cost) {
      final waiting = (summary.totals[who] ?? 0) - available;
      throw InvalidInput('${this.member(who)!.name} needs ${reward.cost - available} more stars for ${reward.title}'
          '${waiting > 0 ? ', since $waiting are waiting on a request' : ''}');
    }
    final id = newId();
    await _commit([
      _Draft(RecordType.redemption, id, Space.family, {
        'reward': rewardId,
        'member': who,
        'cost': reward.cost,
        'status': reward.needsApproval ? RedemptionStatus.requested.name : RedemptionStatus.approved.name,
        'decidedBy': null,
      }),
    ]);
    return id;
  }

  /// Approving is refused when the balance no longer covers the request, so approving several
  /// requests made at once can't overdraw it.
  Future<void> decideRedemption(String id, {required bool approve}) async {
    final r = Redemption(_requireLive(RecordType.redemption, id, 'That request doesn\'t exist').rec);
    final balance = points().totals[r.member] ?? 0;
    if (approve && r.status == RedemptionStatus.requested && balance < r.cost) {
      throw InvalidInput('${member(r.member)?.name ?? 'They'} has $balance stars, not the ${r.cost} this costs');
    }
    await _commit([
      _Draft(RecordType.redemption, id, Space.family, {
        'status': approve ? RedemptionStatus.approved.name : RedemptionStatus.declined.name,
        'decidedBy': actor?.id,
      }),
    ]);
  }

  // ---------------------------------------------------------------- AI and automation connections

  List<Connection> get connections => _memo('connections', () {
        return [for (final e in _visibleLive(RecordType.connection)) Connection(e.rec)]
          ..sort((a, b) => a.label.compareTo(b.label));
      });

  /// Creates an active token connection and returns the bearer token, which is shown once and
  /// stored only as a hash. Parents only.
  Future<String> addTokenConnection({
    required String label,
    required Set<Scope> scopes,
    String? member,
    int? expires,
  }) async {
    if (member != null && this.member(member) == null) throw const InvalidInput('That person isn\'t in the family');
    final token = newBearerToken();
    await _commit([
      _Draft(RecordType.connection, newId(), Space.parents, {
        'label': label,
        'kind': ConnectionKind.token.name,
        'scopes': _scopeNames(scopes),
        'member': member,
        'tokenHash': hashToken(token),
        'client': null,
        'status': ConnectionStatus.active.name,
        'expires': expires,
      }),
    ]);
    return token;
  }

  List<String> _scopeNames(Set<Scope> scopes) => [for (final s in Scope.values) if (scopes.contains(s)) s.name];

  /// Written by a hub when an OAuth client asks for access; a parent then approves or declines it.
  Future<String> requestOAuthConnection({required String label, required String client, required Set<Scope> scopes}) async {
    final id = newId();
    await _commit([
      _Draft(RecordType.connection, id, Space.parents, {
        'label': label,
        'kind': ConnectionKind.oauth.name,
        'scopes': _scopeNames(scopes),
        'member': null,
        'tokenHash': null,
        'client': client,
        'status': ConnectionStatus.pending.name,
        'expires': null,
      }),
    ]);
    return id;
  }

  /// Parents approve a pending connection, optionally narrowing its scopes and choosing whose
  /// permissions it acts with.
  Future<void> approveConnection(String id, {Set<Scope>? scopes, String? member}) async {
    _requireLive(RecordType.connection, id, 'That connection doesn\'t exist');
    if (member != null && this.member(member) == null) throw const InvalidInput('That person isn\'t in the family');
    await _commit([
      _Draft(RecordType.connection, id, Space.parents, {
        'status': ConnectionStatus.active.name,
        if (scopes != null) 'scopes': _scopeNames(scopes),
        'member': ?member,
      }),
    ]);
  }

  /// Records the hash of an OAuth access token issued for an approved connection (hubs only).
  Future<void> setConnectionToken(String id, String tokenHash, {int? expires}) async {
    if (thisDevice?.mode != DeviceMode.hub) throw const PermissionDenied('Only the hub issues access tokens');
    _requireLive(RecordType.connection, id, 'That connection doesn\'t exist');
    await _commit([
      _Draft(RecordType.connection, id, Space.parents, {'tokenHash': tokenHash, 'expires': expires}),
    ]);
  }

  Future<void> revokeConnection(String id) async {
    _requireLive(RecordType.connection, id, 'That connection doesn\'t exist');
    await _commit([
      _Draft(RecordType.connection, id, Space.parents, {'status': ConnectionStatus.revoked.name}),
    ]);
  }

  /// The active, unexpired connection whose token hashes to the given bearer token. Looks at
  /// every connection this device holds, whoever is acting.
  Connection? connectionForToken(String bearerToken) {
    final hash = hashToken(bearerToken);
    final now = _now();
    for (final e in _mat.store.liveOfType(RecordType.connection)) {
      final c = Connection(e.rec);
      if (c.tokenHash != hash || c.status != ConnectionStatus.active) continue;
      if (c.expires != null && c.expires! <= now) continue;
      return c;
    }
    return null;
  }

  // ---------------------------------------------------------------- calendar feeds

  /// Subscribed ICS calendars the actor may see (parents and hubs), by label.
  List<Subscription> get subscriptions => _memo('subscriptions', () {
        return [for (final e in _visibleLive(RecordType.subscription)) Subscription(e.rec)]
          ..sort((a, b) {
            final l = a.label.compareTo(b.label);
            return l != 0 ? l : a.id.compareTo(b.id);
          });
      });

  Subscription? subscription(String id) {
    final e = _visibleEntry(RecordType.subscription, id);
    return e == null ? null : Subscription(e.rec);
  }

  /// Subscribes the family to an ICS feed; the hub fetches it and keeps its events in [space]
  /// (default: [audience]'s), with [category] and [assignee] on each. Parents only.
  Future<String> addSubscription({
    required String url,
    String label = '',
    String? category,
    String? assignee,
    Audience audience = Audience.everyone,
    String? space,
    List<String> include = const [],
    List<String> exclude = const [],
    bool skipAllDay = false,
  }) async {
    if (assignee != null && member(assignee) == null) throw const InvalidInput('That person isn\'t in the family');
    final id = newId();
    await _commit([
      _Draft(RecordType.subscription, id, Space.parents, {
        'url': url,
        'label': label,
        'category': category,
        'assignee': assignee,
        'space': space ?? _spaceFor(audience),
        'include': include,
        'exclude': exclude,
        'skipAllDay': skipAllDay,
        'status': '',
      }),
    ]);
    return id;
  }

  Future<void> updateSubscription(String id, Map<String, Object?> patch) async {
    _requireLive(RecordType.subscription, id, 'That calendar feed doesn\'t exist');
    final fields = _cleanPatch(patch, {'url', 'label', 'category', 'assignee', 'space', 'include', 'exclude', 'skipAllDay'});
    if (fields.isEmpty) return;
    await _commit([_Draft(RecordType.subscription, id, Space.parents, fields)]);
  }

  Future<void> removeSubscription(String id) async {
    _requireLive(RecordType.subscription, id, 'That calendar feed doesn\'t exist');
    await _commit([_Draft(RecordType.subscription, id, Space.parents, {'_deleted': true})]);
  }

  /// Records how the last fetch of a feed went, in words for people. Written by the hub.
  Future<void> setSubscriptionStatus(String id, String status) async {
    _requireLive(RecordType.subscription, id, 'That calendar feed doesn\'t exist');
    await _commit([_Draft(RecordType.subscription, id, Space.parents, {'status': status})]);
  }

  // ---------------------------------------------------------------- views

  TodayView today({String? date}) {
    final d = date ?? todayDate();
    final start = dayStart(d);
    final end = dayStart(addDays(d, 1));
    final events = occurrences(start, end);
    final eventIds = {for (final o in events) o.event.id};
    return TodayView(
      date: d,
      events: events,
      chores: choresOn(d),
      lists: [
        for (final l in lists)
          if (l.list.pinned ||
              (l.list.lifecycle == ListLifecycle.dated && l.list.needBy == d) ||
              (l.list.event != null && eventIds.contains(l.list.event)))
            l,
      ],
      gaps: gaps(start, end),
    );
  }

  /// The family-columns grid from [startDate] for [days] days.
  WeekGrid week(String startDate, {int days = 7}) {
    final dates = [for (var i = 0; i < days; i++) addDays(startDate, i)];
    final people = members;
    final ids = {for (final m in people) m.id};
    final cellEvents = <(String, String), List<Occurrence>>{};
    final cellChores = <(String, String), List<ChoreDay>>{};
    final everyone = <String, List<Occurrence>>{for (final d in dates) d: []};
    for (final d in dates) {
      for (final m in people) {
        cellEvents[(d, m.id)] = [];
        cellChores[(d, m.id)] = [];
      }
    }
    if (dates.isNotEmpty) {
      final all = occurrences(dayStart(dates.first), dayStart(addDays(dates.last, 1)));
      for (final d in dates) {
        final start = dayStart(d), end = dayStart(addDays(d, 1));
        for (final o in all) {
          final overlaps = o.end > o.start ? o.start < end && o.end > start : o.start >= start && o.start < end;
          if (!overlaps) continue;
          final assigned = o.assignees.where(ids.contains).toSet();
          if (o.assignees.isEmpty || assigned.containsAll(ids)) {
            everyone[d]!.add(o);
          } else {
            for (final a in assigned) {
              cellEvents[(d, a)]!.add(o);
            }
          }
        }
        for (final cd in choresOn(d)) {
          if (cd.date == d && cd.owner != null && ids.contains(cd.owner)) cellChores[(d, cd.owner!)]!.add(cd);
        }
      }
    }
    return WeekGrid(
      days: dates,
      people: people,
      cells: {for (final k in cellEvents.keys) k: WeekCell(cellEvents[k]!, cellChores[k]!)},
      everyone: everyone,
    );
  }

  /// Newest first; filtered to what the actor may read.
  List<HistoryEntry> history({String? query, String? member, String? type, int limit = 200}) {
    final readable = readableSpaces;
    final q = query?.trim().toLowerCase();
    final out = <HistoryEntry>[];
    for (final a in _mat.applied.reversed) {
      final c = a.change;
      if (!readable.contains(c.space)) continue;
      if (type != null && c.type != type) continue;
      if (member != null && c.actor != member) continue;
      final entry = _historyEntry(a);
      if (q != null && q.isNotEmpty && !_historyMatches(entry, q)) continue;
      out.add(entry);
      if (out.length >= limit) break;
    }
    return out;
  }

  HistoryEntry _historyEntry(Applied a) {
    final c = a.change;
    final store = _mat.store;
    final deviceName = (store.at(Space.family, RecordType.device, c.device)?.fields['name'] as String?) ?? c.device;
    final actorName = c.actor == null
        ? deviceName
        : (store.at(Space.family, RecordType.member, c.actor!)?.fields['name'] as String?) ?? deviceName;
    return HistoryEntry(
      when: c.hlc,
      actor: c.actor,
      actorName: actorName,
      device: c.device,
      deviceName: deviceName,
      type: c.type,
      rid: c.rid,
      title: a.title,
      verb: a.verb,
      diffs: [
        for (final e in c.fields.entries)
          if (e.key != '_via' && e.key != '_deleted' && e.key != '_from')
            FieldDiff(e.key, _redact(e.key, a.before[e.key]), _redact(e.key, e.value)),
      ],
      space: c.space,
      via: c.fields['_via'] as String?,
      from: CaptureOrigin.parse(c.fields['_from']),
      change: c.id,
    );
  }

  /// History entries for the changes [changeIds] names (what [recording] returned, say), oldest
  /// first. Changes that didn't count, or that the actor may not read, are left out.
  List<HistoryEntry> historyOf(Iterable<String> changeIds) {
    final want = changeIds.toSet();
    final readable = readableSpaces;
    final out = <HistoryEntry>[];
    final applied = _mat.applied;
    for (var i = applied.length - 1; i >= 0 && want.isNotEmpty; i--) {
      final a = applied[i];
      if (!want.remove(a.change.id) || !readable.contains(a.change.space)) continue;
      out.add(_historyEntry(a));
    }
    return out.reversed.toList();
  }

  static Object? _redact(String field, Object? value) {
    if (value == null) return null;
    if (field == 'signIn' && value is Map) return {'kind': value['kind']};
    if (field == 'tokenHash' || field == 'pubkey' || field == 'xpub') return '•••';
    return value;
  }

  static bool _historyMatches(HistoryEntry e, String q) {
    bool has(Object? v) => v is String
        ? v.toLowerCase().contains(q)
        : v is List
            ? v.any(has)
            : v is Map
                ? v.values.any(has)
                : false;
    return e.title.toLowerCase().contains(q) ||
        e.actorName.toLowerCase().contains(q) ||
        e.deviceName.toLowerCase().contains(q) ||
        e.verb == q ||
        e.diffs.any((d) => has(d.after) || has(d.before));
  }

  List<SearchHit> search(String query, {int limit = 50}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final hits = <(int, int, SearchHit)>[];
    final seen = <String>{};
    int rank(String text) {
      final t = text.toLowerCase();
      if (t == q) return 0;
      if (t.startsWith(q)) return 1;
      if (t.split(RegExp(r'\s+')).any((w) => w.startsWith(q))) return 2;
      return t.contains(q) ? 3 : -1;
    }

    void add(int typeOrder, String text, SearchHit hit, [List<String> also = const []]) {
      var r = rank(text);
      for (final extra in also) {
        final ar = rank(extra);
        if (ar >= 0 && (r < 0 || ar + 4 < r)) r = ar + 4;
      }
      if (r < 0 || !seen.add('${hit.type}/${hit.id}')) return;
      hits.add((r, typeOrder, hit));
    }

    for (final m in members) {
      add(0, m.name, SearchHit(type: RecordType.member, id: m.id, title: m.name));
    }
    final now = _now();
    for (final e in events) {
      final next = seriesStarts(e, _zone, notBefore: now).firstOrNull ?? e.start;
      add(1, e.title, SearchHit(type: RecordType.event, id: e.id, title: e.title, detail: e.location.isEmpty ? null : e.location, when: next), [e.location, e.notes]);
    }
    for (final c in chores) {
      add(2, c.title, SearchHit(type: RecordType.chore, id: c.id, title: c.title), [c.notes]);
    }
    for (final l in lists) {
      add(3, l.list.title, SearchHit(type: RecordType.list, id: l.list.id, title: l.list.title));
      for (final i in l.items) {
        add(4, i.text, SearchHit(type: RecordType.item, id: i.id, title: i.text, detail: l.list.title), [i.store ?? '']);
      }
    }
    final readable = readableSpaces;
    for (final a in _mat.applied.reversed) {
      final c = a.change;
      if (!readable.contains(c.space) || a.title.isEmpty) continue;
      if (!const {RecordType.event, RecordType.chore, RecordType.list, RecordType.item}.contains(c.type)) continue;
      add(5, a.title, SearchHit(type: c.type, id: c.rid, title: a.title, detail: 'History', when: c.hlc.millis));
    }
    hits.sort((a, b) {
      if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      return a.$3.title.compareTo(b.$3.title);
    });
    return [for (final h in hits.take(limit)) h.$3];
  }

  String _names(Iterable<String> ids) =>
      joinNames([for (final id in ids) member(id)?.name ?? 'someone']);

  List<Gap> gaps(int start, int end) {
    final occ = occurrences(start, end);
    final out = <Gap>[];
    for (final o in occ) {
      for (final r in o.rides) {
        if (r.driver != null) continue;
        final who = _names(o.assignees);
        final message = r.leg == 'from'
            ? (who.isEmpty ? 'Nobody is picking up from ${o.title}' : 'Nobody is picking up $who from ${o.title}')
            : (who.isEmpty ? 'Nobody is driving to ${o.title}' : 'Nobody is driving $who to ${o.title}');
        out.add(Gap(kind: GapKind.noDriver, message: message, occurrences: [o], members: o.assignees, leg: r.leg));
      }
    }
    // Only people named on both events: an event for everyone would flag nearly everything.
    final everyoneIds = [for (final m in members) m.id];
    final timed = occ.where((o) => !o.allDay && o.end > o.start && o.assignees.isNotEmpty).toList();
    for (var i = 0; i < timed.length; i++) {
      for (var j = i + 1; j < timed.length; j++) {
        final a = timed[i], b = timed[j];
        if (!(a.start < b.end && b.start < a.end)) continue;
        final both = [for (final id in everyoneIds) if (a.assignees.contains(id) && b.assignees.contains(id)) id];
        if (both.isEmpty) continue;
        out.add(Gap(
          kind: GapKind.overlap,
          message: '${_names(both)} ${both.length == 1 ? 'has' : 'have'} ${a.title} and ${b.title} at the same time',
          occurrences: [a, b],
          members: both,
        ));
      }
    }
    final today = todayDate();
    if (dayStart(today) < end && dayStart(addDays(today, 1)) > start) {
      for (final cd in choresOn(today)) {
        if (cd.date == today && cd.owner == null && !cd.done) {
          out.add(Gap(kind: GapKind.unowned, message: '${cd.chore.title} is up for grabs', occurrences: const []));
        }
      }
    }
    return out;
  }

  /// Reminders that fire in [from, to) (UTC ms) for [memberId] (null: for anyone).
  List<ReminderDue> remindersDue(int from, int to, {String? memberId}) {
    final out = <ReminderDue>[];
    final zoneName = _zone;
    var maxLead = 0;
    for (final e in events) {
      for (final m in e.reminders) {
        maxLead = math.max(maxLead, m);
      }
    }
    for (final x in _exceptions.values.expand((m) => m.values)) {
      for (final m in (x.patch['reminders'] as List? ?? const [])) {
        maxLead = math.max(maxLead, (m as num).toInt());
      }
    }
    for (final o in occurrences(from, to + maxLead * 60000 + 1)) {
      if (memberId != null && o.assignees.isNotEmpty && !o.assignees.contains(memberId)) continue;
      for (final minutes in o.reminders.toSet()) {
        final at = o.start - minutes * 60000;
        if (at < from || at >= to) continue;
        final wall = wallTime(zoneName, o.start);
        final when = o.allDay ? 'All day' : (minutes == 0 ? 'Starting now' : 'Starts at ${clockText(wall)}');
        out.add(ReminderDue(
          key: 'event:${o.event.id}:${o.seriesStart}:$minutes',
          at: at,
          title: o.title,
          body: o.location.isEmpty ? when : '$when at ${o.location}',
          members: o.assignees,
        ));
      }
    }
    var choreLead = 0;
    for (final c in chores) {
      for (final m in c.reminders) {
        choreLead = math.max(choreLead, m);
      }
    }
    final firstDate = addDays(dateIn(zoneName, from), -1);
    final lastDate = addDays(dateIn(zoneName, to + choreLead * 60000), 1);
    final seen = <String>{};
    for (var d = firstDate; d.compareTo(lastDate) <= 0; d = addDays(d, 1)) {
      for (final cd in choresOn(d)) {
        final due = cd.chore.dueTime;
        if (cd.done || due == null || !isLocalTime(due) || cd.chore.reminders.isEmpty) continue;
        if (!seen.add('${cd.chore.id}@${cd.date}')) continue;
        if (memberId != null && cd.owner != null && cd.owner != memberId) continue;
        final dueAt = dateTimeIn(zoneName, cd.date, due);
        for (final minutes in cd.chore.reminders.toSet()) {
          final at = dueAt - minutes * 60000;
          if (at < from || at >= to) continue;
          out.add(ReminderDue(
            key: 'chore:${cd.chore.id}:${cd.date}:$minutes',
            at: at,
            title: cd.chore.title,
            body: 'Due at ${clockText(wallTime(zoneName, dueAt))}',
            members: cd.owner == null ? const [] : [cd.owner!],
          ));
        }
      }
    }
    out.sort((a, b) => a.at != b.at ? a.at.compareTo(b.at) : a.key.compareTo(b.key));
    return out;
  }

  // ---------------------------------------------------------------- sync surface

  /// deviceId -> highest contiguous change counter held. Counters below a floor recorded by
  /// [ingest]'s `through` count as held: they belong to spaces this device doesn't receive.
  Map<String, int> get versionVector => _vector(withFloor: true);

  /// deviceId -> highest counter up to which this device holds every change in every space.
  /// A sender whose spaces include the receiver's passes this as [ingest]'s `through`.
  Map<String, int> get completeVector => _vector(withFloor: false);

  Map<String, int> _vector({required bool withFloor}) {
    final out = <String, int>{};
    final counters = _mat.counters;
    for (final d in {...counters.keys, if (withFloor) ..._floor.keys}) {
      var n = withFloor ? _floor[d] ?? 0 : 0;
      final held = counters[d] ?? const <int>{};
      while (held.contains(n + 1)) {
        n++;
      }
      if (n > 0) out[d] = n;
    }
    return out;
  }

  /// How many changes from unknown devices [ingest] keeps waiting in memory.
  static const int maxPending = 5000;

  /// Changes the holder of [vv] lacks, limited to [spaces] when given, in HLC order.
  List<Change> changesSince(Map<String, int> vv, {Set<String>? spaces}) => [
        for (final c in _mat.log)
          if (c.counter > (vv[c.device] ?? 0) && (spaces == null || spaces.contains(c.space))) c,
      ];

  /// Stores and applies changes from another device. Duplicates are ignored; invalid changes are
  /// kept but not applied. Changes whose signature fails are refused and not stored; changes from
  /// a device whose record hasn't arrived wait in memory until it does.
  ///
  /// [through] is the sender's [completeVector] when the sender holds every space this device
  /// receives: after a clean batch, counters up to it count as held, so changes in spaces this
  /// device never receives don't hold its [versionVector] back.
  Future<IngestResult> ingest(Iterable<Change> changes, {Map<String, int>? through}) => _locked(() async {
        var duplicate = 0;
        final candidates = <String, Change>{};
        for (final c in changes) {
          if (_mat.contains(c.id) || candidates.containsKey(c.id)) {
            duplicate++;
          } else {
            candidates[c.id] = c;
          }
        }
        for (final c in _pending.values) {
          candidates.putIfAbsent(c.id, () => c);
        }
        _pending.clear();
        candidates.values.forEach(_learnKey);
        final accepted = <Change>[];
        final rejected = <String, String>{};
        for (final c in candidates.values) {
          final pubkey = _pubkeys[c.device];
          if (pubkey == null) {
            _pending[c.id] = c;
          } else if (await verifySignature(c.signedBytes, c.sig, pubkey)) {
            accepted.add(c);
          } else {
            rejected[c.id] = 'The signature doesn\'t verify';
          }
        }
        while (_pending.length > maxPending) {
          _pending.remove(_pending.keys.first);
        }
        var invalid = const <String, String>{};
        var metaMoved = false;
        if (accepted.isNotEmpty) {
          await _storage.appendChanges(accepted);
          invalid = _mat.add(accepted);
          _observeApplied();
          // This device's own changes coming back from a peer (after a restore from an older
          // backup, say): never number a new change with an id the family already holds.
          for (final c in accepted) {
            if (c.device != deviceId) continue;
            _clock.observe(c.hlc);
            if (c.counter > _counter) {
              _counter = c.counter;
              metaMoved = true;
            }
          }
        }
        if (through != null && rejected.isEmpty && _pending.isEmpty) {
          for (final e in through.entries) {
            if (e.value > (_floor[e.key] ?? 0)) {
              _floor[e.key] = e.value;
              metaMoved = true;
            }
          }
        }
        if (metaMoved) await _saveMeta();
        if (accepted.isNotEmpty) _emit({for (final c in accepted) c.type});
        if (accepted.isNotEmpty) await _afterKeyFacts();
        return IngestResult(
          added: accepted.length,
          duplicate: duplicate,
          invalid: invalid,
          rejected: rejected,
          pending: _pending.length,
        );
      });

  /// The spaces the given device should hold, per its owner, mode and the family's policy.
  Set<String> spacesForDevice(String deviceId) {
    final d = device(deviceId);
    if (d == null || !d.approved || d.revoked) return {};
    final owner = d.member == null ? null : member(d.member!);
    return spacesFor(device: d, owner: owner, family: family, members: members);
  }

  // ---------------------------------------------------------------- space keys

  /// space -> epoch -> candidate keys. Persisted in metadata as `spaceKeys`.
  final Map<String, Map<int, List<SpaceKey>>> _keyring = {};

  /// Keys whose maker's device record hasn't arrived, by `space@epoch@hash`.
  final Map<String, SpaceKey> _pendingKeys = {};

  /// Most candidates kept for one epoch: parents racing each other make two or three.
  static const int maxKeysPerEpoch = 8;

  /// Most keys waiting for their maker's device record.
  static const int maxPendingKeys = 64;

  /// Whether this device may make space keys: an approved hub, or an approved personal device
  /// owned by a parent.
  bool get makesSpaceKeys {
    final d = thisDevice;
    return d != null && _makesKeys(d);
  }

  bool _makesKeys(Device d) {
    if (!d.approved || d.revoked) return false;
    if (d.mode == DeviceMode.hub) return true;
    if (d.mode != DeviceMode.personal || d.member == null) return false;
    return member(d.member!)?.isParent ?? false;
  }

  /// A bound key counts while its maker is this device or an approved device not revoked since:
  /// a key minted by a device after it was revoked (a stolen phone, say) never wins.
  bool _inGoodStanding(SpaceKey key) {
    if (key.by == deviceId) return true;
    final d = device(key.by!);
    return d != null && d.approved && !d.revoked;
  }

  bool _usable(SpaceKey key) => !key.bound || _inGoodStanding(key);

  /// Approved devices that are revoked now: what a new key's statement lists.
  List<String> _revokedDevices() => [
        for (final d in devices)
          if (d.approved && d.revoked) d.id,
      ]..sort();

  /// The current key epoch for a space: the newest epoch with a key this device may seal with
  /// (one stored here without a statement, or one whose maker is in good standing), or null.
  int? spaceKeyEpoch(String space) {
    int? best;
    for (final e in (_keyring[space] ?? const <int, List<SpaceKey>>{}).entries) {
      if ((best == null || e.key > best) && e.value.any(_usable)) best = e.key;
    }
    return best;
  }

  /// The key a space uses at [epoch] (default: the current one), with its maker's statement:
  /// of several keys for one epoch, every replica picks the same ([pickSpaceKey]).
  SpaceKey? currentSpaceKey(String space, {int? epoch}) {
    final e = epoch ?? spaceKeyEpoch(space);
    final list = e == null ? null : _keyring[space]?[e];
    return list == null ? null : pickSpaceKey(list, _inGoodStanding);
  }

  /// Space keys used to seal changes on the relay mailbox: the current one, or the one for
  /// [epoch]. Made at genesis per space and when a member is added, and rotated when a device
  /// that held the space is revoked.
  Future<List<int>?> spaceKey(String space, {int? epoch}) async => currentSpaceKey(space, epoch: epoch)?.key;

  /// Every key held for [space] at [epoch], the one in use first: mailboxes of the others are
  /// still read, since devices may have posted there before they saw the one in use.
  List<SpaceKey> spaceKeysAt(String space, int epoch) {
    final list = _keyring[space]?[epoch];
    if (list == null || list.isEmpty) return const [];
    final winner = pickSpaceKey(list, _inGoodStanding)!;
    return [
      winner,
      for (final k in list)
        if (!identical(k, winner)) k,
    ];
  }

  /// Epochs held for [space], oldest first.
  List<int> spaceKeyEpochs(String space) => (_keyring[space]?.keys.toList() ?? <int>[])..sort();

  /// Stores a key without a statement: trusted on this device, losing to any bound key for the
  /// same epoch, and replacing an earlier key stored this way for it. Older epochs are kept for
  /// reading what was sealed with them.
  Future<void> setSpaceKey(String space, List<int> key, {int epoch = 0}) => _locked(() async {
        if (key.length != 32) throw const InvalidInput('A space key is 32 bytes');
        if (epoch < 0) throw const InvalidInput('A key epoch can\'t be negative');
        final list = _keyring.putIfAbsent(space, () => {}).putIfAbsent(epoch, () => []);
        final k = SpaceKey(space: space, epoch: epoch, key: key);
        if (list.any((c) => c.hash == k.hash)) return;
        list
          ..removeWhere((c) => !c.bound)
          ..add(k);
        await _saveMeta();
      });

  /// Takes a key another device passed on. It is kept when its maker's statement verifies and the
  /// maker may make keys (a parent's device or a hub, approved and not revoked); a key for an
  /// epoch this device already holds becomes another candidate for it. Then, on a device that
  /// makes keys, a space whose key in use may have reached a revoked device is rotated
  /// ([staleSpaceKeys]).
  Future<SpaceKeyOutcome> addSpaceKey(SpaceKey key) => _locked(() async {
        final outcome = await _admitKey(key);
        if (outcome == SpaceKeyOutcome.stored) await _afterKeyFacts();
        return outcome;
      });

  Future<SpaceKeyOutcome> _admitKey(SpaceKey key) async {
    final family = familyId;
    if (!key.bound || family == null) return SpaceKeyOutcome.refused;
    final list = _keyring[key.space]?[key.epoch];
    final same = list?.firstWhereOrNull((c) => c.hash == key.hash);
    if (same != null && same.bound) return SpaceKeyOutcome.duplicate;
    final maker = device(key.by!);
    if (maker == null) {
      if (_pendingKeys.length < maxPendingKeys) _pendingKeys['${key.space}@${key.epoch}@${key.hash}'] = key;
      return SpaceKeyOutcome.waiting;
    }
    if (!_makesKeys(maker) || !await verifySignature(key.statementBytes(family), key.sig!, maker.pubkey)) {
      return SpaceKeyOutcome.refused;
    }
    final held = _keyring.putIfAbsent(key.space, () => {}).putIfAbsent(key.epoch, () => []);
    if (same != null) {
      held.remove(same);
    } else if (held.length >= maxKeysPerEpoch) {
      // Full: keep the lowest hashes, as every replica does, so they still agree on the pick.
      final highest = held.reduce((a, b) => a.hash.compareTo(b.hash) >= 0 ? a : b);
      if (key.hash.compareTo(highest.hash) >= 0) return SpaceKeyOutcome.refused;
      held.remove(highest);
    }
    held.add(key);
    await _saveMeta();
    return SpaceKeyOutcome.stored;
  }

  /// The current key of [space] with a statement, to pass on to another device. A key stored here
  /// without one is signed as this device's own first (listing no revoked devices, since this
  /// device can't vouch for what its maker knew), which only a device that makes keys can do;
  /// otherwise null.
  Future<SpaceKey?> spaceKeyToShare(String space) async {
    final inUse = currentSpaceKey(space);
    if (inUse == null || inUse.bound) return inUse;
    if (!makesSpaceKeys) return null;
    return _locked(() async {
      final current = currentSpaceKey(space);
      if (current == null || current.bound) return current;
      final draft = SpaceKey(space: space, epoch: current.epoch, key: current.key, by: deviceId, sig: '');
      final adopted = draft.signed(by: deviceId, revoked: const [], sig: await _keys.sign(draft.statementBytes(familyId!)));
      _keyring[space]![current.epoch]!
        ..remove(current)
        ..add(adopted);
      await _saveMeta();
      return adopted;
    });
  }

  /// Spaces whose key in use may have reached a revoked device: some key held for the space
  /// lists a device that is revoked now, and the key in use doesn't. Its maker didn't know of
  /// that revocation (two parents revoking while out of touch, or a rotation made before the
  /// news arrived), so it may have handed the key to that device.
  Set<String> get staleSpaceKeys {
    final revoked = _revokedDevices().toSet();
    if (revoked.isEmpty) return const {};
    final stale = <String>{};
    for (final entry in _keyring.entries) {
      final current = currentSpaceKey(entry.key);
      if (current == null) continue;
      final covered = current.revoked.toSet();
      final listed = {
        for (final list in entry.value.values)
          for (final k in list) ...k.revoked,
      };
      if (listed.any((d) => revoked.contains(d) && !covered.contains(d))) stale.add(entry.key);
    }
    return stale;
  }

  /// After new changes or a new key: admits keys whose maker has now arrived, then rotates
  /// stale spaces when this device makes keys. Runs inside the lock.
  Future<void> _afterKeyFacts() async {
    if (_pendingKeys.isNotEmpty) {
      final waiting = Map.of(_pendingKeys);
      _pendingKeys.clear();
      for (final k in waiting.values) {
        await _admitKey(k);
      }
    }
    if (makesSpaceKeys) await _rotateNow(staleSpaceKeys);
  }

  /// A new random key for [space] at [epoch], signed by this device with today's revoked devices.
  Future<SpaceKey> _makeSpaceKey(String space, int epoch) async {
    final revoked = _revokedDevices();
    final draft = SpaceKey(space: space, epoch: epoch, key: randomBytes(32), by: deviceId, revoked: revoked, sig: '');
    return draft.signed(by: deviceId, revoked: revoked, sig: await _keys.sign(draft.statementBytes(familyId!)));
  }

  /// Makes a new key for each of [spaces], one epoch past every epoch held for it. Runs inside
  /// the lock.
  Future<void> _rotateNow(Set<String> spaces) async {
    if (spaces.isEmpty || familyId == null) return;
    for (final s in spaces.toList()..sort()) {
      final epochs = _keyring.putIfAbsent(s, () => {});
      final epoch = epochs.isEmpty ? 0 : epochs.keys.reduce(math.max) + 1;
      epochs[epoch] = [await _makeSpaceKey(s, epoch)];
    }
    await _saveMeta();
  }

  Map<String, Object?> _keyringJson() => {
        for (final s in _keyring.entries)
          s.key: {
            for (final e in s.value.entries)
              '${e.key}': [
                for (final k in e.value)
                  {
                    'k': b64e(k.key),
                    if (k.bound) ...{'by': k.by, 'rv': k.revoked, 'sig': k.sig},
                  },
              ],
          },
      };

  /// Reads `spaceKeys`: space -> {epoch: [{k, by, rv, sig}]}, or, from before keys were bound,
  /// space -> {epoch: key} and space -> key (epoch 0).
  void _loadKeyring(Object? raw) {
    _keyring.clear();
    if (raw is! Map) return;
    for (final s in raw.entries) {
      final space = '${s.key}';
      SpaceKey? parse(int epoch, Object? v) {
        try {
          if (v is String) return SpaceKey(space: space, epoch: epoch, key: b64d(v));
          if (v is! Map) return null;
          final by = v['by'] as String?;
          return SpaceKey(
            space: space,
            epoch: epoch,
            key: b64d(v['k']! as String),
            by: by,
            revoked: [for (final d in (v['rv'] as List?) ?? const []) '$d'],
            sig: by == null ? null : v['sig'] as String?,
          );
        } on Object {
          return null;
        }
      }

      final epochs = <int, List<SpaceKey>>{};
      final value = s.value;
      if (value is String) {
        final k = parse(0, value);
        if (k != null) epochs[0] = [k];
      } else if (value is Map) {
        for (final e in value.entries) {
          final epoch = int.tryParse('${e.key}');
          if (epoch == null || epoch < 0) continue;
          final items = e.value is List ? e.value as List : [e.value];
          final list = [
            for (final item in items) ?parse(epoch, item),
          ];
          if (list.isNotEmpty) epochs[epoch] = list;
        }
      }
      if (epochs.isNotEmpty) _keyring[space] = epochs;
    }
  }

  /// Every live record as JSON, for export: `{family, records: {type: {id: {space, fields}}}}`
  /// with keys in sorted order, so equal state exports equal text.
  Map<String, Object?> exportJson() {
    final readable = readableSpaces;
    final byType = <String, Map<String, Object?>>{};
    for (final type in RecordType.all.toList()..sort()) {
      final entries = [
        for (final e in _mat.store.liveOfType(type))
          if (readable.contains(e.space)) e,
      ]..sort((a, b) {
          final i = a.id.compareTo(b.id);
          return i != 0 ? i : a.space.compareTo(b.space);
        });
      if (entries.isEmpty) continue;
      final records = <String, Object?>{};
      for (final e in entries) {
        records[records.containsKey(e.id) ? '${e.id}@${e.space}' : e.id] = {
          'space': e.space,
          'fields': _sortedJson(e.fields),
        };
      }
      byType[type] = records;
    }
    return {'family': familyId, 'records': byType};
  }

  static Object? _sortedJson(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: _sortedJson(v[k])};
    }
    if (v is List) return [for (final e in v) _sortedJson(e)];
    return v;
  }

  // ---------------------------------------------------------------- internals

  void _setRoot(String familyId, String founderPubkey) {
    _meta['familyId'] = familyId;
    _meta['founderPubkey'] = founderPubkey;
    _root = TrustRoot(familyId: familyId, founderPubkey: founderPubkey);
    final founder = _root.founderDevice;
    if (founder != null) _pubkeys[founder] = founderPubkey;
  }

  void _loadMeta() {
    final familyId = _meta['familyId'], founder = _meta['founderPubkey'];
    if (familyId is String && founder is String) _setRoot(familyId, founder);
    final counter = _meta['counter'];
    if (counter is int) _counter = counter;
    final floor = _meta['floor'];
    if (floor is Map) {
      for (final e in floor.entries) {
        if (e.value is int) _floor['${e.key}'] = e.value as int;
      }
    }
    _loadKeyring(_meta['spaceKeys']);
  }

  Future<void> _saveMeta() async {
    _meta['counter'] = _counter;
    _meta['floor'] = Map<String, Object?>.of(_floor);
    _meta['spaceKeys'] = _keyringJson();
    await _storage.saveMeta(Map.of(_meta));
  }

  /// Device ids are hashes of their keys, so a key found in any device record that hashes to the
  /// record's id is that device's key.
  void _learnKey(Change c) {
    if (c.type != RecordType.device || _pubkeys.containsKey(c.rid)) return;
    final pubkey = c.fields['pubkey'];
    if (pubkey is String && deviceIdOf(pubkey) == c.rid) _pubkeys[c.rid] = pubkey;
  }

  Future<T> _locked<T>(Future<T> Function() body) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await body());
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }

  Future<List<Change>> _commit(List<_Draft> drafts) => _locked(() => _commitNow(drafts));

  Future<List<Change>> _commitNow(List<_Draft> drafts) async {
    if (drafts.isEmpty) return const [];
    final made = <Change>[];
    var counter = _counter;
    final acting = actor?.id;
    final via = thisDevice?.mode == DeviceMode.hub ? actingVia : null;
    final zoned = Zone.current[_origins];
    final origin = zoned is CaptureOrigin ? zoned : null;
    try {
      for (final d in drafts) {
        counter++;
        while (_mat.contains('$deviceId:$counter')) {
          counter++;
        }
        final from = origin != null && d.fields['_deleted'] != true && !d.fields.containsKey('_from') ? origin.toJson() : null;
        final unsigned = Change(
          id: '$deviceId:$counter',
          space: d.space,
          hlc: d.hlc ?? _clock.next(),
          type: d.type,
          rid: d.rid,
          fields: {...d.fields, '_from': ?from, '_via': ?via},
          device: deviceId,
          actor: d.setsActor ? d.actor : acting,
          sig: '',
        );
        final rejection = _mat.check(unsigned);
        if (rejection != null) throw rejection.toException();
        final signed = Change(
          id: unsigned.id,
          space: unsigned.space,
          hlc: unsigned.hlc,
          type: unsigned.type,
          rid: unsigned.rid,
          fields: unsigned.fields,
          device: deviceId,
          actor: unsigned.actor,
          sig: await _keys.sign(unsigned.signedBytes),
        );
        final invalid = _mat.add([signed]);
        if (invalid.isNotEmpty) throw PermissionDenied(invalid.values.first);
        made.add(signed);
      }
      await _storage.appendChanges(made);
    } on Object {
      _mat.remove([for (final c in made) c.id]);
      rethrow;
    }
    _counter = counter;
    await _saveMeta();
    final sinks = Zone.current[_recorders];
    if (sinks is List<List<String>>) {
      for (final ids in sinks) {
        ids.addAll([for (final c in made) c.id]);
      }
    }
    _emit({for (final c in made) c.type});
    return made;
  }

  void _emit(Set<String> types) {
    if (!_changes.isClosed && types.isNotEmpty) _changes.add(types);
  }

  T _memo<T>(String key, T Function() build) {
    final actorId = actor?.id;
    if (_cacheVersion != _mat.store.version || _cacheActor != actorId) {
      _cache.clear();
      _cacheVersion = _mat.store.version;
      _cacheActor = actorId;
    }
    return _cache.putIfAbsent(key, build) as T;
  }

  Iterable<Entry> _visibleLive(String type) {
    final readable = readableSpaces;
    return _mat.store.liveOfType(type).where((e) => readable.contains(e.space));
  }

  Entry? _visibleEntry(String type, String id) {
    final e = _mat.store.find(type, id);
    if (e == null || e.deleted || !readableSpaces.contains(e.space)) return null;
    return e;
  }

  Entry _requireLive(String type, String id, String missing) => _visibleEntry(type, id) ?? (throw InvalidInput(missing));

  String _spaceFor(Audience audience) {
    if (audience == Audience.justMe) {
      final a = actor;
      if (a == null) throw const InvalidInput('Choose who this is for');
      return Space.member(a.id);
    }
    return audience.spaceFor('');
  }

  static Audience _audienceOf(Object value) {
    if (value is Audience) return value;
    final found = Audience.values.firstWhereOrNull((a) => a.name == value);
    if (found == null) throw const InvalidInput('Who can see it must be everyone, parents, or just me');
    return found;
  }

  static String? _normalizeRule(String? rule) {
    if (rule == null || rule.trim().isEmpty) return null;
    try {
      return RecurrenceRule.parse(rule).toString();
    } on FormatException {
      throw InvalidInput('"$rule" isn\'t a repeat rule Den understands');
    }
  }

  /// Checks a patch's keys and turns enum values into their names.
  static Map<String, Object?> _cleanPatch(Map<String, Object?> patch, Set<String> allowed) {
    for (final k in patch.keys) {
      if (!allowed.contains(k)) throw InvalidInput('"$k" can\'t be changed here');
    }
    return {
      for (final e in patch.entries)
        e.key: e.value is Enum && e.key != 'audience' ? (e.value as Enum).name : e.value,
    };
  }

  /// Moves a record and its children (records whose [parentField] names it) to another space,
  /// keeping ids: new copies in the target space, removals in the old one.
  List<_Draft> _moveDrafts(Entry entry, String target, Map<String, Object?> patch, String childType, String parentField) {
    Map<String, Object?> copyOf(Entry e) => {
          for (final f in e.fields.entries)
            if (!f.key.startsWith('_')) f.key: f.value,
        };
    final children = [
      for (final c in _mat.store.liveOfType(childType))
        if (c.space == entry.space && c.fields[parentField] == entry.id) c,
    ];
    return [
      _Draft(entry.type, entry.id, target, {...copyOf(entry), ...patch}),
      for (final c in children) _Draft(childType, c.id, target, copyOf(c)),
      for (final c in children) _Draft(childType, c.id, entry.space, {'_deleted': true}),
      _Draft(entry.type, entry.id, entry.space, {'_deleted': true}),
    ];
  }
}
