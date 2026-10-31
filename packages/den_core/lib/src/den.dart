import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';

import 'account.dart';
import 'calendar.dart';
import 'change.dart';
import 'chores.dart';
import 'family_controls.dart';
import 'hlc.dart';
import 'ids.dart';
import 'invite_keys.dart';
import 'materializer.dart';
import 'model.dart';
import 'names.dart';
import 'order_keys.dart';
import 'parallel.dart';
import 'permissions.dart';
import 'points.dart';
import 'recovery.dart';
import 'rrule.dart';
import 'schema.dart';
import 'secrets.dart';
import 'snapshot.dart';
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

/// What [Den.disownInvite] did about a device an invite let in that nobody recognized: whose
/// it was meant to be, and the devices it let in since, still in the family.
class DisownedInvite {
  const DisownedInvite({required this.member, required this.letIn});

  /// Who the invite was for; null for a shared screen or the hub.
  final String? member;

  /// Devices the removed one let in, directly or through ones it let in, still in the family.
  final List<Device> letIn;
}

/// What [Den.disownRecovery] did about a phone recovery let in that nobody recognized.
class DisownedRecovery {
  const DisownedRecovery({required this.member, required this.kind, required this.retired, required this.letIn});

  /// The parent it got in as.
  final String member;

  /// Whether their words or the hub's help let it in.
  final RecoveryKind kind;

  /// Whether those were turned off now; false when they had been replaced or turned off since.
  final bool retired;

  /// Devices it let in, directly or through devices it let in, still in the family.
  final List<Device> letIn;
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

  /// Memoized views, least recently used first ([_memo]).
  final Map<String, _Memo> _memos = {};

  /// The occurrences of each repeating event (or one with changed occurrences) in the windows
  /// asked for lately, by the event's record as it is now.
  Map<Rec, _EventOccurrences> _occurrenceCache = {};

  // Snapshots (see [SnapshotStorage]): written only to storage that keeps them.
  late final bool _snapshots = _storage is SnapshotStorage;

  /// Change id -> its digest hash ([changeHash]), for every change held, once known.
  final Map<String, Uint8List> _hashes = {};

  /// False while [open]'s background check of the stored log runs; no snapshot is written until
  /// it has vouched for every change.
  bool _settled = true;
  bool _closed = false;

  /// Bumped when the device leaves its family, so work started before can't write after.
  int _generation = 0;

  /// How many changes the stored snapshot covers, and its window's first change: a change
  /// ordered before that makes the next open replay from scratch, so the snapshot is written
  /// again ([_staleMarks]).
  int _snapshotCount = 0;
  Change? _snapshotBoundary;
  int _staleMarks = 0;
  int _staleSaved = 0;
  Future<void>? _snapshotting;

  // ---------------------------------------------------------------- lifecycle and identity

  /// Loads the device's log and metadata from [storage] and materializes state.
  static Future<Den> open({
    required DenStorage storage,
    required DeviceKeys keys,
    int Function()? now,
  }) =>
      _open(storage, keys, now);

  /// [open]; with [copying], the state is copied from that engine's (whose log [storage] holds)
  /// instead of replayed.
  static Future<Den> _open(DenStorage storage, DeviceKeys keys, int Function()? now, {Materializer? copying}) async {
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
    SnapshotHeader? snapshot;
    if (storage is SnapshotStorage && copying == null) {
      try {
        final text = await (storage as SnapshotStorage).loadSnapshot();
        if (text != null) snapshot = SnapshotHeader.parse(text);
      } on Object {
        snapshot = null;
      }
    }
    if (snapshot != null && (snapshot.familyId != den._root.familyId || snapshot.founderPubkey != den._root.founderPubkey)) {
      snapshot = null;
    }
    // From the snapshot, with the changes it doesn't cover on top; else the whole log.
    final rest = snapshot == null ? null : den._mat.restore(snapshot, changes, root: den._root);
    den._fromSnapshot = rest != null;
    if (copying != null) {
      den._mat.copyFrom(copying);
    } else {
      den._mat.add(rest ?? changes);
    }
    den._observeApplied();
    var own = 0;
    for (final c in changes) {
      if (c.device != den.deviceId) continue;
      den._clock.observe(c.hlc);
      own = math.max(own, c.counter);
    }
    den._counter = math.max(den._counter, own);
    if (den._snapshots && copying == null) {
      den._settled = false;
      den._settling = den._settle(changes, snapshot, restored: rest != null);
    }
    engineProbes[den] = den._probe;
    return den;
  }

  Future<void>? _settling;
  bool _fromSnapshot = false;

  /// What tests see of the work [open] started.
  EngineProbe get _probe => EngineProbe(
        fullReplays: () => _mat.fullReplays,
        openedFromSnapshot: () => _fromSnapshot,
        idle: () async {
          await _settling;
          while (_snapshotting != null) {
            await _snapshotting;
          }
        },
      );

  /// After [open], off the critical path: checks the stored log against the snapshot it opened
  /// from. The changes the snapshot covers must still give its digest (so stored changes that were
  /// altered are caught without checking every signature again); the others, stored since it was
  /// written, have their signatures checked. A change that fails is dropped, as if it had never
  /// arrived. Without a snapshot (a log from before snapshots, or one that couldn't be used) the
  /// stored log is trusted as before, every change having been checked when it arrived.
  ///
  /// Then, with every change vouched for, a snapshot is written if one is due.
  Future<void> _settle(List<Change> held, SnapshotHeader? snapshot, {required bool restored}) async {
    final generation = _generation;
    bool gone() => _closed || generation != _generation;
    try {
      await Future<void>.delayed(Duration.zero);
      final seen = <String>{};
      final covered = <Change>[], unvouched = <Change>[];
      for (final c in held) {
        if (!seen.add(c.id) || !_mat.contains(c.id)) continue;
        (snapshot == null || snapshot.covers(c.id) ? covered : unvouched).add(c);
      }
      final bad = <String>{};
      var mismatch = false;
      final checked = await checkChanges(unvouched, pubkeys: [for (final c in unvouched) _pubkeys[c.device]]);
      if (gone()) return;
      for (var i = 0; i < unvouched.length; i++) {
        final h = checked[i];
        if (h == null || !await recoveryProofHolds(unvouched[i], familyId) || !await inviteProofHolds(unvouched[i], familyId) ||
            !await accountProofHolds(unvouched[i], familyId)) {
          bad.add(unvouched[i].id);
        } else {
          _hashes[unvouched[i].id] = h;
        }
      }
      // The digest of everything else is a lot of hashing: not while the first screens draw.
      await Future<void>.delayed(snapshotCheckDelay);
      if (gone()) return;
      final hashes = await checkChanges(covered, verify: false);
      if (gone()) return;
      for (var i = 0; i < covered.length; i++) {
        _hashes[covered[i].id] = hashes[i]!;
      }
      if (snapshot != null) {
        covered.sort(changeOrder);
        final digest = digestOf([for (final c in covered) _hashes[c.id]!]);
        if (!_sameBytes(digest, snapshot.digest)) {
          // Stored changes the snapshot vouched for aren't the ones it saw: check them all, and
          // build the state from what is stored rather than from the snapshot.
          final again = await checkChanges(covered, pubkeys: [for (final c in covered) _pubkeys[c.device]]);
          if (gone()) return;
          for (var i = 0; i < covered.length; i++) {
            if (again[i] == null) bad.add(covered[i].id);
          }
          mismatch = true;
          _staleMarks++;
        } else {
          _snapshotCount = snapshot.count;
          final first = snapshot.windowFirst;
          _snapshotBoundary = first != null ? _mat.byId(first) : (covered.isEmpty ? null : covered.last);
          if (!restored) _staleMarks++;
        }
      }
      if (bad.isNotEmpty || mismatch) {
        await _locked(() async {
          if (gone()) return;
          final types = mismatch ? RecordType.all : {for (final id in bad) ?_mat.byId(id)?.type};
          for (final id in bad) {
            _hashes.remove(id);
          }
          _mat.remove(bad);
          if (mismatch) _mat.replay();
          _staleMarks++;
          _emit(types);
        });
      }
      if (gone()) return;
      _settled = true;
      _maybeSnapshot();
    } on Object {
      // Left unsettled: no snapshot is written this time, and the next open checks again.
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Writes a snapshot when enough has changed since the last, or the last no longer fits. A log
  /// shorter than [snapshotEvery] replays quickly enough without one.
  void _maybeSnapshot() {
    if (!_snapshots || !_settled || _closed || _snapshotting != null || !hasFamily) return;
    final held = _mat.log.length;
    if (held < snapshotEvery) return;
    if (_staleMarks == _staleSaved && held - _snapshotCount < snapshotEvery) return;
    _snapshotting = _writeSnapshot().whenComplete(() {
      _snapshotting = null;
      if (_mat.log.length >= snapshotEvery && (_staleMarks != _staleSaved || _mat.log.length - _snapshotCount >= snapshotEvery)) {
        // Still behind (it moved on while this one was written): only if this one got written.
        if (_lastSnapshotOk) _maybeSnapshot();
      }
    });
  }

  bool _lastSnapshotOk = false;

  /// Copies the state (inside the lock, so no write is half applied), encodes it while the engine
  /// moves on, and saves it unless the device left its family meanwhile.
  Future<void> _writeSnapshot() async {
    _lastSnapshotOk = false;
    try {
      await Future<void>.delayed(Duration.zero);
      final generation = _generation;
      SnapshotCapture? capture;
      var marks = 0;
      await _locked(() async {
        if (_closed || generation != _generation || !hasFamily) return;
        final log = _mat.log;
        final hashes = <List<int>>[];
        for (final c in log) {
          final h = _hashes[c.id];
          if (h == null) return;
          hashes.add(h);
        }
        marks = _staleMarks;
        capture = _mat.capture(root: _root, windowFrom: _now() - snapshotWindow.inMilliseconds, digest: digestOf(hashes));
      });
      final taken = capture;
      if (taken == null) return;
      final text = await taken.encode();
      await _locked(() async {
        if (generation != _generation) return;
        await (_storage as SnapshotStorage).saveSnapshot(text);
        _snapshotCount = taken.log.length;
        _snapshotBoundary = taken.boundary;
        _staleSaved = marks;
        _lastSnapshotOk = true;
      });
    } on Object {
      // Not written: the next open replays more of the log, and a later write tries again.
    }
  }

  /// Notes changes just added to the log: one ordered before the stored snapshot's window means
  /// the snapshot should be written again.
  void _noteAdded(Iterable<Change> added) {
    final boundary = _snapshotBoundary;
    if (!_snapshots || boundary == null) return;
    if (added.any((c) => changeOrder(c, boundary) < 0)) _staleMarks++;
  }

  /// Keeps this device's clock past every valid change, so its next write is the newest. Invalid
  /// changes don't move it: a device nobody approved can't push the family's clocks ahead.
  void _observeApplied() {
    final newest = _mat.newestApplied;
    if (newest != null) _clock.observe(newest);
  }

  /// Ends the [onChange] stream and the acting window's timer.
  Future<void> close() async {
    _closed = true;
    _actingTimer?.cancel();
    _actingTimer = null;
    await _snapshotting;
    await _changes.close();
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

  /// On a shared screen: tells the family's parents that someone got [memberId]'s PIN or picture
  /// pattern wrong [tries] times in a row here (a `signInTries` record in the family space, so
  /// it travels like any change and History shows it). Written for nobody, whoever is acting:
  /// it is the screen that saw it.
  Future<void> noteSignInTries(String memberId, int tries) async {
    if (thisDevice?.mode != DeviceMode.shared) throw const PermissionDenied('Only a shared screen says that');
    if (member(memberId) == null) throw const InvalidInput('That person isn\'t in the family');
    await _commit([
      _Draft(RecordType.signInTries, newId(), Space.family, {'device': deviceId, 'member': memberId, 'tries': tries},
          actor: null, setsActor: true),
    ]);
  }

  /// What shared screens said about wrong PIN and pattern tries ([noteSignInTries]), newest
  /// first.
  List<SignInTries> get signInTries => _memo('signInTries', const {RecordType.signInTries}, visible: false, () {
        return [
          for (final e in _mat.store.liveOfType(RecordType.signInTries))
            if (e.space == Space.family) SignInTries(e.rec),
        ]..sort((a, b) => b.rec.created.compareTo(a.rec.created));
      });

  /// Writes the genesis changes: the family, the founding parent and this device, approved.
  Future<void> createFamily({
    required String familyName,
    required String timezone,
    required String yourName,
    Marker marker = Marker.sky,
    Animal animal = Animal.cat,
    String picture = Picture.initial,
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
              'picture': picture,
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

  /// Lets this new device into the family as [proof]'s parent's own device: one change to its
  /// own device record, approved, carrying the proof (see recovery.dart). This device holds
  /// none of the family's log yet, so it can't check the change itself; it is written as is,
  /// counts for nothing here until the family's log arrives, and every device that receives it
  /// decides by the same rules.
  Future<void> requestRecovery({
    required String familyId,
    required String founderPubkey,
    required String deviceName,
    required DeviceKind kind,
    required RecoveryProof proof,
  }) =>
      _selfApprove(familyId: familyId, founderPubkey: founderPubkey, fields: {
        'name': deviceName,
        'kind': kind.name,
        'pubkey': _keys.pubkey,
        'xpub': _keys.xpub,
        'member': proof.member,
        'mode': DeviceMode.personal.name,
        'approved': true,
        'recovery': proof.toJson(),
      });

  /// Writes this new device's own record letting itself in with [fields] (a recovery or invite
  /// proof among them), as is: it can't check the change before the family's log arrives.
  Future<void> _selfApprove({
    required String familyId,
    required String founderPubkey,
    required Map<String, Object?> fields,
  }) =>
      _locked(() async {
        if (hasFamily && this.familyId != familyId) throw StateError('This device already belongs to a family');
        if (isApproved) throw StateError('This device is already in the family');
        if (deviceIdOf(founderPubkey) == null) throw const InvalidInput('The founder key isn\'t valid');
        if (!hasFamily) {
          _setRoot(familyId, founderPubkey);
          _mat.replay();
        }
        var counter = _counter + 1;
        while (_mat.contains('$deviceId:$counter')) {
          counter++;
        }
        final unsigned = Change(
          id: '$deviceId:$counter',
          space: Space.family,
          hlc: _clock.next(),
          type: RecordType.device,
          rid: deviceId,
          fields: fields,
          device: deviceId,
          actor: null,
          sig: '',
        );
        final signed = Change(
          id: unsigned.id,
          space: unsigned.space,
          hlc: unsigned.hlc,
          type: unsigned.type,
          rid: unsigned.rid,
          fields: unsigned.fields,
          device: deviceId,
          actor: null,
          sig: await _keys.sign(unsigned.signedBytes),
        );
        await _storage.appendChanges([signed]);
        _mat.add([signed]);
        _counter = counter;
        await _saveMeta();
        _emit({RecordType.device});
      });

  /// Lets this new device into the family as [proof]'s person's own device with an invite a
  /// parent made (invite_keys.dart): one change to its own device record, approved, carrying
  /// the proof. Like [requestRecovery], this device holds none of the family's log yet, so the
  /// change counts for nothing here until the log arrives, and every device that receives it
  /// decides by the same rules.
  Future<void> requestInviteJoin({
    required String familyId,
    required String founderPubkey,
    required String deviceName,
    required DeviceKind kind,
    required InviteProof proof,
  }) =>
      _selfApprove(familyId: familyId, founderPubkey: founderPubkey, fields: {
        'name': deviceName,
        'kind': kind.name,
        'pubkey': _keys.pubkey,
        'xpub': _keys.xpub,
        'member': proof.member,
        'mode': proof.mode.name,
        'approved': true,
        if (proof.mode == DeviceMode.shared) 'display': _defaultDisplay,
        'invite': proof.toJson(),
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
        _memos.clear();
        _occurrenceCache = {};
        _generation++;
        _hashes.clear();
        _snapshotCount = 0;
        _snapshotBoundary = null;
        _staleMarks = _staleSaved = 0;
        _settled = true;
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
  List<Member> get members => _memo('members', const {RecordType.member}, visible: false, () {
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

  List<Device> get devices => _memo('devices', const {RecordType.device}, visible: false, () {
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

  List<EventCategory> get categories => _memo('categories', const {RecordType.category}, visible: false, () {
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
  Set<String> get readableSpaces => _memo('readable', _whoReadsWhat, visible: false, () {
        if (!isApproved) return const <String>{};
        final held = spacesForDevice(deviceId);
        final a = actor;
        if (a == null) return held;
        final f = family;
        return Set<String>.unmodifiable({for (final s in held) if (canRead(a, s, f)) s});
      });

  /// What decides who may read which spaces: the family's policy, its people and its devices.
  static const Set<String> _whoReadsWhat = {RecordType.family, RecordType.member, RecordType.device};

  Future<void> updateFamily(Map<String, Object?> patch) async {
    final id = familyId;
    if (id == null || family == null) throw const InvalidInput('There is no family yet');
    final fields = _cleanPatch(patch, {
      'name', 'timezone', 'weekStart', 'capture', 'pointsEnabled', 'colors', 'oversight', 'assistant',
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
    Marker? marker,
    Animal animal = Animal.cat,
    String picture = Picture.initial,
    String? birthday,
    Set<Grant> grants = const {},
  }) async {
    final id = newId();
    final color = marker ?? Marker.next(members.map((m) => m.marker));
    final order = members.isEmpty ? 0 : members.map((m) => m.order).reduce(math.max) + 1;
    await _commit([
      _Draft(RecordType.member, id, Space.family, {
        'name': name,
        'role': role.name,
        'tier': tier?.name,
        'marker': color.name,
        'animal': animal.name,
        'picture': picture,
        'birthday': birthday,
        'grants': [for (final g in Grant.values) if (grants.contains(g)) g.name],
        'signIn': {'kind': 'none', 'salt': null, 'hash': null},
        'order': order,
      }),
    ]);
    await _locked(() => _rotateNow({Space.member(id)}));
    return id;
  }

  /// Changes a person. Making a parent anything else takes their recovery words away in the
  /// same change ([_noRecovery]): if they're a parent again later, they make new ones.
  Future<void> updateMember(String id, Map<String, Object?> patch) => _locked(() async {
        final m = member(id);
        if (m == null) throw const InvalidInput('That person isn\'t in the family');
        final fields = _cleanPatch(patch, {'name', 'role', 'tier', 'marker', 'animal', 'picture', 'birthday', 'until', 'grants', 'order'});
        final grants = fields['grants'];
        if (grants is Iterable) fields['grants'] = [for (final g in grants) g is Enum ? g.name : g];
        final role = fields['role'];
        final demoted = role != null && role != Role.parent.name;
        if (demoted) fields.addAll(_noRecovery(m));
        await _commitNow([
          // Their invites let nobody in now, even a device clocked before this. First, while
          // whoever does this is still a parent (they may be changing their own role).
          if (demoted) ..._retireInvites((k) => k.by == id),
          _Draft(RecordType.member, id, Space.family, fields),
        ]);
      });

  /// Removes a member and revokes the devices they own, rotating the keys of the spaces those
  /// devices held. Their recovery words go first, in the same commit ([_noRecovery]).
  Future<void> removeMember(String id) => _locked(() async {
        final m = member(id);
        if (m == null) throw const InvalidInput('That person isn\'t in the family');
        final owned = [
          for (final d in devices)
            if (d.member == id && d.id != deviceId && !d.revoked) d.id,
        ];
        final held = {for (final d in owned) ...spacesForDevice(d)};
        final words = _noRecovery(m);
        await _commitNow([
          // The invites they made, and those for them, let nobody in now.
          ..._retireInvites((k) => k.by == id || k.member == id || owned.contains(k.device)),
          for (final d in owned) _revocation(d),
          if (words.isNotEmpty) _Draft(RecordType.member, id, Space.family, words),
          _Draft(RecordType.member, id, Space.family, {'_deleted': true}),
        ]);
        await _rotateNow(held);
      });

  /// The fields that take [m]'s recovery words away, naming the devices they let in that this
  /// device holds (which stay), or nothing when they have none. Old words can then let nobody
  /// in, even with a recovery change clocked before this one (recovery.dart).
  Map<String, Object?> _noRecovery(Member m) {
    final key = recoveryKeyOf(m);
    if (key == null) return const {};
    return {
      'recovery': {'key': null, 'kept': keptBy(_mat.store, key: key, member: m.id)},
    };
  }

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

  /// Binds [account] (from the hub's sign-in with Google or Apple, ARCHITECTURE.md "Accounts") to
  /// [memberId], so that account signs in as them; null takes it away. Only a parent binds their
  /// own, on their own personal device; they, or any parent there, may take one away. The hub can
  /// never write this (validity.dart).
  Future<void> setAccount(String memberId, AccountRef? account) async {
    final m = member(memberId);
    if (m == null) throw const InvalidInput('That person isn\'t in the family');
    final a = actor;
    final d = thisDevice;
    if (a == null || d == null || d.mode != DeviceMode.personal || d.member != a.id) {
      throw const PermissionDenied('Only a parent on their own phone can do that');
    }
    if (account != null && (a.id != memberId || !a.isParent)) {
      throw const PermissionDenied('Only the parent themselves can choose the account they sign in with');
    }
    if (account == null && a.id != memberId && !a.isParent) {
      throw const PermissionDenied('Only a parent can take away the account someone signs in with');
    }
    if (account != null) {
      // The hub's proof, checked here as every replica checks it when the change arrives.
      final proof = account.proof;
      final family = familyId;
      if (proof == null || family == null || !await proof.verifies(family: family, member: memberId, account: account)) {
        throw const PermissionDenied('Only an account the family\'s hub saw sign in for you can be bound');
      }
    }
    await _commit([_Draft(RecordType.member, memberId, Space.family, {'account': account?.toJson()})]);
  }

  /// The earliest time (UTC milliseconds) the next change this engine makes can be clocked at:
  /// now, or the latest change it has made or seen, when that is later. A proof that must still
  /// hold at a change's clock (`AccountProof.expires`) counts from here.
  int get clockMillis => math.max(now(), _clock.millis);

  /// The member [account] signs in as, or null for none, or when more than one member has it
  /// (two bindings made while apart both stand: the hub then signs in as neither, and
  /// [sharedAccounts] tells the parents).
  Member? memberWithAccount(AccountRef account) {
    final found = [for (final m in members) if (m.account == account) m];
    return found.length == 1 ? found.single : null;
  }

  /// Accounts bound to more than one member, each with those members: none of them signs in
  /// with it until all but one take it away. Parents see it in Needs you.
  List<List<Member>> sharedAccounts() {
    final by = <AccountRef, List<Member>>{};
    for (final m in members) {
      final a = m.account;
      if (a != null) (by[a] ??= []).add(m);
    }
    return [for (final list in by.values) if (list.length > 1) list];
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
        // The invites made on it go with it, taken away first: a device may remove itself.
        await _commitNow([..._retireInvites((k) => k.device == deviceId), _revocation(deviceId)]);
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

  // ---------------------------------------------------------------- recovery (recovery.dart)

  /// Sets [memberId]'s recovery key: the public half of the key their 12 recovery words stretch
  /// to (den_net's `RecoveryWords`), or null to remove it. Only the parent themselves sets
  /// theirs, on their own device; any parent there may remove one. Replacing a key names the
  /// devices the old one let in that this device holds, so old words can't let in a phone
  /// clocked before the change.
  Future<void> setRecoveryKey(String memberId, String? publicKey) => _locked(() async {
        final m = member(memberId);
        if (m == null) throw const InvalidInput('That person isn\'t in the family');
        final old = recoveryKeyOf(m);
        await _commitNow([
          _Draft(RecordType.member, memberId, Space.family, {
            'recovery': {
              'key': publicKey,
              'kept': old == null ? <String>[] : keptBy(_mat.store, key: old, member: memberId),
            },
          }),
        ]);
      });

  /// Lets the hub with server recovery key [publicKey] help a parent back in (`family.recovery`),
  /// or with null stops it, after which that key lets nobody in. A parent on their own device.
  Future<void> setServerRecoveryKey(String? publicKey) => _locked(() async {
        final id = familyId;
        final f = family;
        if (id == null || f == null) throw const InvalidInput('There is no family yet');
        final old = serverRecoveryKeyOf(f);
        await _commitNow([
          _Draft(RecordType.family, id, Space.family, {
            'recovery': {
              'serverKey': publicKey,
              'kept': old == null ? <String>[] : keptBy(_mat.store, key: old, hub: true),
            },
          }),
        ]);
      });

  /// "That wasn't us", for a phone recovery let in ([recoveryOf]): removes it (rotating the keys
  /// of what it held), and takes away what let it in while the family still trusts it, in the
  /// same commit: that parent's words (keeping the devices they let in that this device holds,
  /// the phone among them, so what it did stays on record), or the hub's help. Whoever used them
  /// can then let nobody in, even with a recovery change clocked before this one. Returns that,
  /// and the devices the phone let in since, directly or through devices it let in, still in
  /// the family: for the parent to remove too ([revokeDevice]).
  Future<DisownedRecovery> disownRecovery(String deviceId) => _locked(() async {
        final d = device(deviceId);
        final proof = d == null ? null : recoveryOf(d);
        if (d == null || proof == null) throw const InvalidInput('That device wasn\'t let in by recovery');
        final held = deviceId == this.deviceId ? const <String>{} : spacesForDevice(deviceId);
        var retired = false;
        final drafts = <_Draft>[..._retireInvites((k) => k.device == deviceId), if (!d.revoked) _revocation(deviceId)];
        final m = member(proof.member);
        final f = family;
        if (proof.kind == RecoveryKind.words && m != null && recoveryKeyOf(m) == proof.key) {
          retired = true;
          drafts.add(_Draft(RecordType.member, m.id, Space.family, {
            'recovery': {'key': null, 'kept': keptBy(_mat.store, key: proof.key, member: m.id)},
          }));
        } else if (proof.kind == RecoveryKind.hub && f != null && serverRecoveryKeyOf(f) == proof.key) {
          retired = true;
          drafts.add(_Draft(RecordType.family, familyId!, Space.family, {
            'recovery': {'serverKey': null, 'kept': keptBy(_mat.store, key: proof.key, hub: true)},
          }));
        }
        await _commitNow(drafts);
        await _rotateNow(held);
        return DisownedRecovery(member: proof.member, kind: proof.kind, retired: retired, letIn: letInBy(deviceId));
      });

  // ---------------------------------------------------------------- invites (invite_keys.dart)

  /// Every invite key the family made, newest first, withdrawn and used ones too.
  List<InviteKeyRecord> get inviteKeys => _memo('inviteKeys', const {RecordType.inviteKey}, visible: false, () {
        return [
          for (final e in _mat.store.ofType(RecordType.inviteKey))
            if (e.space == Space.family) InviteKeyRecord(e.rec),
        ]..sort((a, b) => b.rec.created.compareTo(a.rec.created));
      });

  /// The invite key [id], or null.
  InviteKeyRecord? inviteKey(String id) {
    final e = _mat.store.at(Space.family, RecordType.inviteKey, id);
    return e == null ? null : InviteKeyRecord(e.rec);
  }

  /// How many more devices the invite key of [record] may let in, not counting [except].
  int inviteUses(InviteKeyRecord record, {String? except}) => inviteUsesLeft(_mat.store, record, except: except);

  /// The device an invite key let in, or null while nobody used it.
  Device? usedInvite(String id) => devices.firstWhereOrNull((d) => inviteOf(d)?.invite == id);

  /// Makes an invite that lets [uses] devices in at once, until [expires] (UTC milliseconds, at
  /// most [inviteKeyMaxLife] away): as [member]'s own, or, for no one, as a shared screen or the
  /// hub ([modes]). The public half of its key goes in the family's log, signed by this parent's
  /// own device; the secret half goes in the invite. Returns the record's id ([inviteKeyIdOf] the
  /// key), which the proof names.
  Future<String> createInviteKey({
    required String? member,
    required String publicKey,
    required int expires,
    Set<DeviceMode> modes = const {DeviceMode.personal},
    int uses = 1,
  }) =>
      _locked(() async {
        if (member != null && this.member(member) == null) throw const InvalidInput('That person isn\'t in the family');
        final id = inviteKeyIdOf(publicKey);
        if (id == null) throw const InvalidInput('That isn\'t an invite key');
        if (inviteKey(id) != null) throw const InvalidInput('That invite key was used before');
        await _commitNow([
          _Draft(RecordType.inviteKey, id, Space.family, {
            'member': member,
            if (modes.length != 1 || modes.single != DeviceMode.personal)
              'modes': [for (final m in DeviceMode.values) if (modes.contains(m)) m.name],
            if (uses != 1) 'uses': uses,
            'key': publicKey,
            'by': actor?.id,
            'device': deviceId,
            'expires': expires,
          }),
        ]);
        return id;
      });

  /// Withdraws invite [id]: its key lets nobody else in, even a device clocked before this.
  /// A device it already let in stays (it is named in `kept`).
  Future<void> withdrawInviteKey(String id) => _locked(() async {
        final k = inviteKey(id);
        if (k == null) throw const InvalidInput('That invite doesn\'t exist');
        if (k.key == null) return;
        await _commitNow([_retire(k)]);
      });

  /// "That wasn't Dad", for a device an invite let in ([inviteOf]): removes it (rotating the
  /// keys of what it held) and takes the invite's key away in the same commit, keeping the
  /// device on record so what it did stays in History. Returns whose it was meant to be and
  /// the devices it let in since, still in the family, for the parent to remove too.
  Future<DisownedInvite> disownInvite(String deviceId) => _locked(() async {
        final d = device(deviceId);
        final proof = d == null ? null : inviteOf(d);
        if (d == null || proof == null) throw const InvalidInput('That device didn\'t join with an invite');
        final held = deviceId == this.deviceId ? const <String>{} : spacesForDevice(deviceId);
        final k = inviteKey(proof.invite);
        await _commitNow([
          if (k != null && k.key != null) _retire(k),
          ..._retireInvites((other) => other.device == deviceId),
          if (!d.revoked) _revocation(deviceId),
        ]);
        await _rotateNow(held);
        return DisownedInvite(member: proof.member, letIn: letInBy(deviceId));
      });

  /// Takes the keys away from the live invites [which] picks, each naming the devices it let in
  /// that this device holds (which stay).
  List<_Draft> _retireInvites(bool Function(InviteKeyRecord k) which) => [
        for (final k in inviteKeys)
          if (k.key != null && which(k)) _retire(k),
      ];

  _Draft _retire(InviteKeyRecord k) =>
      _Draft(RecordType.inviteKey, k.id, Space.family, {'key': null, 'kept': inviteKeptBy(_mat.store, k.key!)});

  /// The devices still in the family that [deviceId] approved, then those they approved, and
  /// so on, each device's in the order it approved them.
  List<Device> letInBy(String deviceId) {
    final byApprover = <String, List<Device>>{};
    for (final d in devices) {
      // A device an invite let in approved itself: it counts as let in by the invite's device.
      final invite = inviteOf(d);
      final made = invite == null ? null : _mat.store.at(Space.family, RecordType.inviteKey, invite.invite);
      final by = made != null ? InviteKeyRecord(made.rec).device : d.rec.fieldTimes['approved']?.device;
      if (by != null && by != d.id && d.approved) (byApprover[by] ??= []).add(d);
    }
    for (final list in byApprover.values) {
      list.sort((a, b) => a.rec.fieldTimes['approved']!.compareTo(b.rec.fieldTimes['approved']!));
    }
    final out = <Device>[];
    final seen = {deviceId};
    final queue = [deviceId];
    while (queue.isNotEmpty) {
      for (final d in byApprover[queue.removeAt(0)] ?? const <Device>[]) {
        if (!seen.add(d.id)) continue;
        queue.add(d.id);
        if (!d.revoked) out.add(d);
      }
    }
    return out;
  }

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
  ///   `patch.<field>`) at a time, ride drivers one leg at a time with the `rides` list older
  ///   versions read written again from them (or an older version's list put back, when that
  ///   was what the record read);
  /// - points given or taken get a new adjustment the other way, since adjustments never change.
  ///
  /// What it leaves alone is reported in [UndoResult.skipped]: fields someone changed since
  /// (theirs is newer), a record someone removed or restored since, and what Den can't take
  /// back: adding or removing a person (removal revokes their devices and rotates keys), device
  /// and AI-access changes, and asking for a reward.
  Future<UndoResult> undo(Iterable<String> changeIds) => _locked(() async {
        final plan = _planUndo(changeIds);
        final made = await _commitNow(_closingRequests(plan.drafts));
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
    final copy = await Den._open(storage, _keys, _now, copying: _mat);
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
    'family.colors': 'bright',
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
      // Ride drivers and the list written for older versions alongside them
      // ([_olderVersionsFirst]): see [_undoRides].
      final mirror = switch (type) { RecordType.event => 'rides', RecordType.eventException => 'patch.rides', _ => null };
      bool isDrivers(String f) => type == RecordType.event ? f == 'drivers' || f.startsWith('drivers.') : f.startsWith('patch.drivers.');
      final rides = mirror != null && firstTouch.keys.any(isDrivers);
      UndoSkip? mirrorSkipped;
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
        // Only ever written as it already was (an occurrence's `event` and `occurrence`, which every
        // change to it names): nothing to take back, and nobody's change since is in the way.
        if (!at.absent.contains(f) &&
            list.every((a) => !a.change.fields.containsKey(f) || const DeepCollectionEquality().equals(a.change.fields[f], at.before[f]))) {
          continue;
        }
        final newer = later.firstWhereOrNull((o) => o.change.hlc > at.change.hlc && _touches(o.change, f));
        if (newer != null) {
          final s = skip('${_historyEntry(newer).actorName} changed it since', f);
          if (rides && f == mirror) {
            mirrorSkipped = s;
          } else {
            skipped.add(s);
          }
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
      if (rides) {
        final unset = {for (final e in firstTouch.entries) if (e.value.absent.contains(e.key)) e.key};
        if (!_undoRides(entry, c0, restore, isDrivers, unset)) mirrorSkipped = null;
      }
      if (mirrorSkipped != null) skipped.add(mirrorSkipped);
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

  /// What [_planUndo] puts back of an event's or occurrence's rides, in [restore] (the field
  /// values it would put back) for changes from [c0] on. When the record read its whole `rides`
  /// list before [c0] (an older version's, or one occurrence's own legs), that list comes back,
  /// with the drivers kept out of its way. Otherwise the drivers come back, field by field, and
  /// the list is written again from what they read then: the one there may only have said what
  /// drivers said at some other time. An event's leg the changes added ([unset] names the fields
  /// they first set) goes, with the whole map. Returns whether the list itself comes back, so
  /// that someone having changed it since is worth saying.
  bool _undoRides(Entry entry, Change c0, Map<String, Object?> restore, bool Function(String) isDrivers, Set<String> unset) {
    final event = entry.type == RecordType.event;
    final before = _recBefore(c0);
    final whole = before != null && (event ? !Event(before).readsDrivers : EventException(before).ridesWhole);
    if (whole) {
      if (event) {
        restore.removeWhere((k, _) => isDrivers(k));
      } else {
        for (final k in [...restore.keys.where(isDrivers)]) {
          restore[k] = null;
        }
      }
      return true;
    }
    restore.remove(event ? 'rides' : 'patch.rides');
    if (!restore.keys.any(isDrivers)) return false;
    if (event) {
      final map = restore['drivers'] ?? entry.fields['drivers'];
      final added = {for (final k in restore.keys) if (k.startsWith('drivers.') && unset.contains(k)) k};
      final after = <String, Object?>{
        if (map is Map) ...Map<String, Object?>.from(map),
        for (final k in restore.keys)
          if (k.startsWith('drivers.') && !added.contains(k)) k.substring(8): restore[k],
      }..removeWhere((leg, _) => added.contains('drivers.$leg'));
      if (added.isNotEmpty) {
        restore
          ..removeWhere((k, _) => k.startsWith('drivers.'))
          ..['drivers'] = after;
      }
      restore['rides'] = ridesJson([
        for (final leg in rideLegs)
          if (after.containsKey(leg)) Ride(leg, after[leg] as String?),
      ]);
    } else {
      final after = {
        ...EventException(entry.rec).patch,
        for (final e in restore.entries)
          if (e.key.startsWith('patch.')) e.key.substring(6): e.value,
      }..remove('rides');
      final series = _mat.store.at(entry.space, RecordType.event, '${entry.fields['event']}');
      final own = rideLegs.any((leg) => after['drivers.$leg'] != null);
      restore['patch.rides'] = own && series != null ? ridesJson(EventException.ridesOver(Event(series.rec).rides, after)) : null;
    }
    return false;
  }

  /// The record [c] changed as it was just before [c]: its own earlier changes, applied again.
  Rec? _recBefore(Change c) {
    final store = RecordStore();
    for (final a in _mat.applied) {
      final x = a.change;
      if (changeOrder(x, c) >= 0) break;
      if (x.type == c.type && x.rid == c.rid && x.space == c.space) store.apply(x);
    }
    return store.at(c.space, c.type, c.rid)?.rec;
  }

  // ---------------------------------------------------------------- calendar

  /// Live events the actor may see, by start.
  List<Event> get events => _memo('events', const {RecordType.event}, () {
        return [for (final e in _visibleLive(RecordType.event)) _eventOf(e.rec)]
          ..sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : a.id.compareTo(b.id));
      });

  /// One [Event] per version of an event record, wherever it's asked for.
  final Expando<Event> _eventViews = Expando();
  Event _eventOf(Rec rec) => _eventViews[rec] ??= Event(rec);

  /// The live events the actor may see, sorted for windows: those that happen once and have no
  /// changed occurrence, by start (with the longest one's length, how far before a window one can
  /// start and still reach into it), and the rest, which repeat or have changed occurrences.
  ({List<Entry> once, List<int> starts, int longest, List<Entry> others}) get _eventIndex =>
      _memo('eventIndex', const {RecordType.event, RecordType.eventException}, () {
        final exceptions = _exceptions;
        final once = <(int, Entry)>[];
        final others = <Entry>[];
        var longest = 0;
        for (final e in _visibleLive(RecordType.event)) {
          final f = e.fields;
          if (_repeats(f['rrule']) || (exceptions[e.space]?.containsKey(e.id) ?? false)) {
            others.add(e);
          } else {
            final start = (f['start'] as num).toInt();
            once.add((start, e));
            final length = (f['end'] as num).toInt() - start;
            if (length > longest) longest = length;
          }
        }
        once.sort((a, b) {
          final s = a.$1.compareTo(b.$1);
          return s != 0 ? s : a.$2.id.compareTo(b.$2.id);
        });
        return (once: [for (final o in once) o.$2], starts: [for (final o in once) o.$1], longest: longest, others: others);
      });

  /// Whether an event with this `rrule` repeats, as [ruleOf] reads it.
  static bool _repeats(Object? rrule) {
    if (rrule is! String || rrule.isEmpty) return false;
    try {
      RecurrenceRule.parse(rrule);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Changed occurrences the actor may see: space -> event id -> series start -> the change.
  Map<String, Map<String, Map<int, EventException>>> get _exceptions =>
      _memo('exceptions', const {RecordType.eventException}, () {
        final out = <String, Map<String, Map<int, EventException>>>{};
        for (final e in _visibleLive(RecordType.eventException)) {
          final x = EventException(e.rec);
          ((out[e.space] ??= {})[x.event] ??= {})[x.occurrence] = x;
        }
        return out;
      });

  Map<int, EventException> _exceptionsFor(Event e) => _exceptions[e.space]?[e.id] ?? const {};

  /// Occurrences overlapping [start, end) (UTC ms), exceptions applied, sorted by start.
  List<Occurrence> occurrences(int start, int end) => List.of(_occurrencesIn(start, end));

  /// [occurrences], shared: kept until an event, an occurrence or the family's time zone changes,
  /// and then worked out again only for the events that changed.
  List<Occurrence> _occurrencesIn(int start, int end) =>
      _memo('occurrences|$start|$end', const {RecordType.event, RecordType.eventException, RecordType.family}, () {
        final zoneName = _zone;
        final index = _eventIndex;
        final out = <Occurrence>[];
        // Events that happen once: only those starting in the window, or before it by no more
        // than the longest one lasts, can reach into it.
        final starts = index.starts;
        var lo = 0, hi = starts.length;
        final from = start - index.longest;
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          if (starts[mid] < from) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        for (var i = lo; i < starts.length && starts[i] < end; i++) {
          out.addAll(occurrencesOf(_eventOf(index.once[i].rec), const {}, start, end, zoneName));
        }
        // The rest, kept per event and window until the event or its occurrences change.
        final kept = _occurrenceCache;
        final next = <Rec, _EventOccurrences>{};
        for (final entry in index.others) {
          final e = _eventOf(entry.rec);
          final exceptions = _exceptionsFor(e);
          var cached = kept[e.rec];
          if (cached == null || !cached.holds(exceptions, zoneName)) cached = _EventOccurrences(exceptions, zoneName);
          next[e.rec] = cached;
          out.addAll(cached.window(start, end) ?? cached.keep(start, end, occurrencesOf(e, exceptions, start, end, zoneName)));
        }
        _occurrenceCache = next;
        out.sort(_compareOccurrences);
        return out;
      });

  /// [compareOccurrences], then which occurrence of the series: so an occurrence moved onto
  /// another's start always sorts the same way.
  static int _compareOccurrences(Occurrence a, Occurrence b) {
    final c = compareOccurrences(a, b);
    return c != 0 ? c : a.seriesStart.compareTo(b.seriesStart);
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
    _checkDrivers(rides, const []);
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
        if (rides.isEmpty) 'rides': const <Object?>[] else ...eventRideFields(rides),
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
    final fields = _cleanPatch(patch, {...eventFields.keys.where((k) => k != 'drivers'), 'audience'});
    final audience = fields.remove('audience');
    if (fields.containsKey('rrule')) fields['rrule'] = _normalizeRule(fields['rrule'] as String?);
    final rides = fields.containsKey('rides') ? _ridesInput(fields.remove('rides')) : null;
    if (audience != null) {
      final target = _spaceFor(_audienceOf(audience));
      if (target != entry.space) {
        if (rides != null) _checkDrivers(rides, event.rides);
        await _commit(_moveDrafts(entry, target, fields, RecordType.eventException, 'event', rides: rides));
        return;
      }
    }
    if (fields.isEmpty && rides == null) return;
    if (event.rrule == null || scope == EditScope.all) {
      if (rides != null) {
        _checkDrivers(rides, event.rides);
        fields.addAll(eventRideFields(rides, existing: event));
        if (fields.isEmpty) return;
      }
      await _commit(_seriesDrafts(entry, event, fields, occurrence));
      return;
    }
    if (occurrence == null) throw const InvalidInput('Choose which occurrence to change');
    if (!isSeriesStart(event, _zone, occurrence)) throw const InvalidInput('That isn\'t an occurrence of this event');
    if (scope == EditScope.one) {
      if (fields.keys.any((k) => !patchableEventFields.contains(k))) {
        throw const InvalidInput('That can only be changed for the whole series');
      }
      final x = _exceptionAt(entry, occurrence);
      final ridesFields = <String, Object?>{};
      if (rides != null) {
        _checkDrivers(rides, x?.rides(event.rides) ?? event.rides);
        ridesFields.addAll(occurrenceRideFields(rides, event.rides, x));
      }
      if (fields.isEmpty && ridesFields.isEmpty) return;
      await _commit([
        _Draft(RecordType.eventException, '$id@$occurrence', entry.space, {
          'event': id,
          'occurrence': occurrence,
          'cancelled': false,
          for (final e in fields.entries) 'patch.${e.key}': e.value,
          ...ridesFields,
        }),
      ]);
      return;
    }
    if (rides != null) _checkDrivers(rides, event.rides);
    if (occurrence == firstSeriesStart(event, _zone)) {
      if (rides != null) fields.addAll(eventRideFields(rides, existing: event));
      if (fields.isEmpty) return;
      await _commit(_seriesDrafts(entry, event, fields, occurrence));
      return;
    }
    await _commit(_splitDrafts(entry, event, fields, occurrence, rides: rides));
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
              'patch': _patchToCopy(x, _seriesRidesAfter(event, fields)),
            }));
        }
      }
    } else if (fields['end'] is int && repeating && occurrence != null) {
      out['end'] = shiftWall(zoneName, event.start, wallDelta(zoneName, occurrence, fields['end'] as int));
    }
    return [_Draft(RecordType.event, event.id, entry.space, out), ...drafts];
  }

  List<_Draft> _splitDrafts(Entry entry, Event event, Map<String, Object?> fields, int occurrence, {List<Ride>? rides}) {
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
      ..._eventRidesToCopy(entry, rides),
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
          'patch': _patchToCopy(x, rides ?? event.rides),
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

  /// Sets the driver of a ride leg for one occurrence (null releases it). Only a parent or an
  /// adult drives ([canDrive]).
  ///
  /// It writes that leg alone (`drivers.<leg>`, or `patch.drivers.<leg>` for one occurrence of a
  /// series), so two people taking different legs at once both count, after the whole `rides`
  /// list older versions read ([eventRideFields], [occurrenceRideFields]). Nothing is written
  /// when that leg already has that driver.
  Future<void> claimRide(String eventId, {required int occurrence, required String leg, String? driver}) async {
    if (!rideLegs.contains(leg)) throw const InvalidInput('A ride leg is "to" or "from"');
    if (driver != null) _checkDriver(driver);
    final entry = _requireLive(RecordType.event, eventId, 'That event doesn\'t exist');
    final event = Event(entry.rec);
    if (event.rrule == null) {
      final fields = eventRideFields(ridesWith(event.rides, leg, driver), existing: event);
      if (fields.isNotEmpty) await _commit([_Draft(RecordType.event, eventId, entry.space, fields)]);
      return;
    }
    if (!isSeriesStart(event, _zone, occurrence)) throw const InvalidInput('That isn\'t an occurrence of this event');
    final x = _exceptionAt(entry, occurrence);
    final fields = occurrenceRideFields(ridesWith(x?.rides(event.rides) ?? event.rides, leg, driver), event.rides, x);
    if (fields.isEmpty) return;
    await _commit([
      _Draft(RecordType.eventException, '$eventId@$occurrence', entry.space, {
        'event': eventId,
        'occurrence': occurrence,
        ...fields,
      }),
    ]);
  }

  /// The live change to the occurrence of [entry] whose series start is [occurrence], if any.
  EventException? _exceptionAt(Entry entry, int occurrence) {
    final x = _mat.store.liveAt(entry.space, RecordType.eventException, '${entry.id}@$occurrence');
    return x == null ? null : EventException(x.rec);
  }

  /// Refuses a driver who isn't in the family or may not drive ([canDrive]).
  void _checkDriver(String id) {
    final m = member(id);
    if (m == null) throw const InvalidInput('That person isn\'t in the family');
    if (!canDrive(m)) throw InvalidInput('${m.name} can\'t drive: in Den, parents and adults drive');
  }

  /// [_checkDriver] for each driver [rides] names that [now] doesn't already have on that leg.
  void _checkDrivers(List<Ride> rides, List<Ride> now) {
    for (final r in rides) {
      final driver = r.driver;
      if (driver != null && !now.any((n) => n.leg == r.leg && n.driver == driver)) _checkDriver(driver);
    }
  }

  /// Rides as [updateEvent] takes them: [Ride]s, or maps like the `rides` field's.
  static List<Ride> _ridesInput(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) throw const InvalidInput('Rides must be a list');
    return [
      for (final Object? r in raw)
        switch (r) {
          final Ride ride when rideLegs.contains(ride.leg) => ride,
          final Map map when rideLegs.contains(map['leg']) && (map['driver'] == null || map['driver'] is String) =>
            Ride(map['leg'] as String, map['driver'] as String?),
          _ => throw const InvalidInput('Each ride is a leg, "to" or "from", and who drives it'),
        },
    ];
  }

  /// The ride fields of an event record about to be copied into a new one (a split series, a
  /// move to another space), which gets one time for all its fields: what it reads now, or
  /// [rides] instead, in both forms. Nothing for an event that has only a `rides` list and isn't
  /// given new ones: its copy reads the same.
  static Map<String, Object?> _eventRidesToCopy(Entry entry, List<Ride>? rides) {
    if (rides == null && !entry.fields.containsKey('drivers')) return const {};
    return eventRideFields(rides ?? Event(entry.rec).rides);
  }

  /// An occurrence's patch to copy into a new record, which gets one time for all of it, over its
  /// series' [series]: without its per-leg drivers when `patch.rides` says its rides whole, so the
  /// copy reads the same; else with `rides` as it reads now, for older versions.
  static Map<String, Object?> _patchToCopy(EventException x, List<Ride> series) {
    final patch = x.patch;
    if (x.ridesWhole) return patch..removeWhere((k, _) => k.startsWith('drivers.'));
    if (rideLegs.any((leg) => patch['drivers.$leg'] != null)) patch['rides'] = ridesJson(x.rides(series));
    return patch;
  }

  /// The rides a series has once [fields] (a series edit's) are written.
  static List<Ride> _seriesRidesAfter(Event event, Map<String, Object?> fields) =>
      fields['rides'] is List ? _ridesInput(fields['rides']) : event.rides;

  // ---------------------------------------------------------------- chores

  List<Chore> get chores => _memo('chores', const {RecordType.chore}, () {
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
  List<ChoreDay> choresOn(String date) => List.of(_choresOn(date));

  /// What chores and their check-offs show, with who's who and the family's week.
  static const Set<String> _choreReads = {RecordType.chore, RecordType.completion, RecordType.member, RecordType.family};

  /// [choresOn], shared: kept until a chore, a check-off or who's who changes, or the minute does
  /// (a chore turns late at its due time).
  List<ChoreDay> _choresOn(String date) {
    final today = todayDate();
    final wall = wallTime(_zone, _now());
    final nowMinutes = wall.hour * 60 + wall.minute;
    return _memo('choresOn|$date|$today|$nowMinutes', _choreReads, () => _choresOnNow(date, today, nowMinutes));
  }

  List<ChoreDay> _choresOnNow(String date, String today, int nowMinutes) {
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
      for (final cd in _choresOn(addDays(today, -i))) {
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

  /// Refuses checking off a day still to come for anyone who may complete only their own chores
  /// (a kid, a guest, open check-off): its stars would count now. Someone who may complete
  /// anyone's can, when a chore really was done early.
  void _notAhead(String date) {
    if (date.compareTo(todayDate()) <= 0) return;
    final a = actor;
    if (a != null && can(a, DenAction.completeAnyChore)) return;
    throw const InvalidInput('That day hasn\'t come yet; a chore is checked off on its day');
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
    if (done) _notAhead(date);
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
    if (checked) _notAhead(date);
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
  List<ListState> get lists => _memo('lists', const {RecordType.list, RecordType.item}, () {
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
  List<Reward> get rewards => _memo('rewards', const {RecordType.reward}, () {
        return [for (final e in _visibleLive(RecordType.reward)) Reward(e.rec)]
          ..sort((a, b) {
            final c = a.cost.compareTo(b.cost);
            return c != 0 ? c : a.title.compareTo(b.title);
          });
      });

  /// Every goal the actor may see, by title.
  List<Goal> get goals => _memo('goals', const {RecordType.goal}, () {
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

  /// Changes a reward. Retiring it (`active: false`) declines the requests for it still waiting
  /// for a parent, so nobody waits on a reward that's gone; bringing it back doesn't reopen
  /// them (undo does).
  Future<void> updateReward(String id, Map<String, Object?> patch) async {
    _requireLive(RecordType.reward, id, 'That reward doesn\'t exist');
    await _commit(_closingRequests([
      _Draft(RecordType.reward, id, Space.family,
          _cleanPatch(patch, typeSpecs[RecordType.reward]!.fields.keys.toSet())),
    ]));
  }

  /// [drafts], plus a decline for every request waiting on a reward they retire or remove. A
  /// request the actor made for themselves stays: nobody decides their own.
  List<_Draft> _closingRequests(List<_Draft> drafts) {
    final closing = {
      for (final d in drafts)
        if (d.type == RecordType.reward && (d.fields['active'] == false || d.fields['_deleted'] == true)) d.rid,
    };
    if (closing.isEmpty) return drafts;
    final who = actor?.id;
    return [
      ...drafts,
      for (final e in _mat.store.liveOfType(RecordType.redemption))
        if (e.space == Space.family &&
            closing.contains(e.fields['reward']) &&
            e.fields['status'] == RedemptionStatus.requested.name &&
            (who == null || e.fields['member'] != who))
          _Draft(RecordType.redemption, e.id, Space.family, {
            'status': RedemptionStatus.declined.name,
            'decidedBy': who,
          }),
    ];
  }

  /// Asks to spend points on a reward for [member] (default: the actor). Rewards that don't
  /// need approval, and anyone's whose parents turned off "Rewards need my OK"
  /// ([Family.rewardsNeedOk]), are approved at once, except a points manager's own request,
  /// which always waits for someone else (they could make any reward need no asking). Refused
  /// when the balance, less what requests still waiting for a parent would spend, is short.
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
    final a = actor;
    final ownAsManager = a != null && a.id == who && can(a, DenAction.managePoints);
    await _commit([
      _Draft(RecordType.redemption, id, Space.family, {
        'reward': rewardId,
        'member': who,
        'cost': reward.cost,
        // No OK is needed when the reward says so or a parent let this person trade without asking.
        'status': ownAsManager || (reward.needsApproval && (family?.rewardsNeedOk(who) ?? true))
            ? RedemptionStatus.requested.name
            : RedemptionStatus.approved.name,
        'decidedBy': null,
      }),
    ]);
    return id;
  }

  /// Approving is refused when the balance no longer covers the request, so approving several
  /// requests made at once can't overdraw it.
  /// Approving needs someone other than the person it's for and the person who asked for it
  /// (a parent asking on a kid's behalf waits for the other parent, like anyone): otherwise a
  /// connection acting as a parent could ask and approve in two calls.
  Future<void> decideRedemption(String id, {required bool approve}) async {
    final r = Redemption(_requireLive(RecordType.redemption, id, 'That request doesn\'t exist').rec);
    final who = actor?.id;
    if (approve && r.status == RedemptionStatus.requested && who != null && (r.member == who || r.rec.createdBy == who)) {
      throw PermissionDenied(r.member == who
          ? 'Someone else needs to approve ${member(who)?.name ?? 'your'}\'s reward'
          : '${member(who)?.name ?? 'Whoever'} asked for this, so someone else needs to approve it');
    }
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

  List<Connection> get connections => _memo('connections', const {RecordType.connection}, () {
        return [for (final e in _visibleLive(RecordType.connection)) Connection(e.rec)]
          ..sort((a, b) => a.label.compareTo(b.label));
      });

  /// Creates an active token connection and returns the bearer token, which is shown once and
  /// stored only as a hash. Parents only. It acts as [member], by default the parent making it:
  /// every connection acts as someone, so "me" means a person and a request and its approval
  /// can be told apart. [tz] is the time zone its person lives in, when not the family's.
  Future<String> addTokenConnection({
    required String label,
    required Set<Scope> scopes,
    String? member,
    int? expires,
    String? tz,
  }) async {
    if (member != null && this.member(member) == null) throw const InvalidInput('That person isn\'t in the family');
    final who = member ?? actor?.id;
    final token = newBearerToken();
    await _commit([
      _Draft(RecordType.connection, newId(), Space.parents, {
        'label': label,
        'kind': ConnectionKind.token.name,
        'scopes': _scopeNames(scopes),
        'member': ?who,
        'tokenHash': hashToken(token),
        'client': null,
        'status': ConnectionStatus.active.name,
        'expires': expires,
        'tz': ?_connectionZone(tz),
      }),
    ]);
    return token;
  }

  /// [tz] as a connection keeps it: null for none or the family's own zone.
  String? _connectionZone(String? tz) {
    final t = tz?.trim();
    if (t == null || t.isEmpty || t == _zone) return null;
    if (!isKnownZone(t)) throw InvalidInput('Den doesn\'t know the time zone "$t"');
    return t;
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

  /// Parents approve a pending connection, optionally narrowing its scopes, and choose who it acts
  /// as: [member], by default the parent approving it. [tz] is the time zone its person lives
  /// in, when not the family's.
  Future<void> approveConnection(String id, {Set<Scope>? scopes, String? member, String? tz}) async {
    _requireLive(RecordType.connection, id, 'That connection doesn\'t exist');
    if (member != null && this.member(member) == null) throw const InvalidInput('That person isn\'t in the family');
    final who = member ?? actor?.id;
    await _commit([
      _Draft(RecordType.connection, id, Space.parents, {
        'status': ConnectionStatus.active.name,
        if (scopes != null) 'scopes': _scopeNames(scopes),
        'member': ?who,
        'tz': ?_connectionZone(tz),
      }),
    ]);
  }

  /// Changes who an approved connection acts as, or the time zone its person lives in (an empty
  /// [tz] for the family's). Parents, on their own device.
  Future<void> updateConnection(String id, {String? member, String? tz}) async {
    final entry = _requireLive(RecordType.connection, id, 'That connection doesn\'t exist');
    if (member != null && this.member(member) == null) throw const InvalidInput('That person isn\'t in the family');
    final current = Connection(entry.rec);
    final zone = tz == null ? current.tz : _connectionZone(tz);
    final fields = <String, Object?>{
      if (member != null && member != current.member) 'member': member,
      if (zone != current.tz) 'tz': zone,
    };
    if (fields.isEmpty) return;
    await _commit([_Draft(RecordType.connection, id, Space.parents, fields)]);
  }

  /// Who [c] acts as: its member, or, for a connection approved before every connection was
  /// bound to a person, the parent who let it in (the owner of the device that made it active;
  /// only a parent's own device can). Null when that parent is no longer a parent in the
  /// family, or [c] isn't active: such a connection only reads.
  String? connectionActsAs(Connection c) {
    final named = c.member;
    if (named != null) return member(named) == null ? null : named;
    if (c.status != ConnectionStatus.active) return null;
    final at = c.rec.fieldTimes['status'];
    final owner = at == null ? null : device(at.device)?.member;
    final m = owner == null ? null : member(owner);
    return m != null && m.isParent ? m.id : null;
  }

  /// Records the hash of an OAuth access token issued for an approved connection, or clears it
  /// with null (hubs only). A hub now keeps the hashes of the hourly tokens it issues in its own
  /// state, not the log, and clears the one an older hub recorded here.
  Future<void> setConnectionToken(String id, String? tokenHash, {int? expires}) async {
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

  /// The live connection with [id], whoever is acting: for a hub checking an access token it
  /// keeps the hash of outside the log.
  Connection? connectionWithId(String id) {
    final e = _mat.store.liveAt(Space.parents, RecordType.connection, id);
    return e == null ? null : Connection(e.rec);
  }

  // ---------------------------------------------------------------- pictures, sitters, privacy

  /// A person's photo record, or null.
  Photo? photo(String id) {
    final e = _mat.store.liveAt(Space.family, RecordType.photo, id);
    return e == null ? null : Photo(e.rec);
  }

  /// Makes [bytes] (a [Photo.side]-pixel square JPEG or WebP of at most [Photo.maxBytes], made
  /// small on this device) [memberId]'s picture: a new photo record in the family space and
  /// their `picture` naming it, in one commit. A parent may set anyone's; a person their own,
  /// a kid when a parent allows it ([Family.ownsPicture]). Returns the photo's id.
  Future<String> setPhoto(String memberId, List<int> bytes) async {
    final m = member(memberId);
    if (m == null) throw const InvalidInput('That person isn\'t in the family');
    final format = photoFormat(bytes);
    if (format == null) throw const InvalidInput('A photo must be a JPEG or WebP');
    if (bytes.length > Photo.maxBytes) throw InvalidInput('That photo is too big (${Photo.maxBytes ~/ 1024} KB at most)');
    if (!canChangePicture(actor, m, family)) {
      throw PermissionDenied('${actor?.name ?? 'This screen'} can\'t change ${m.name}\'s picture');
    }
    final id = newId();
    await _commit([
      _Draft(RecordType.photo, id, Space.family, {'member': memberId, 'mime': format.mime, 'data': base64.encode(bytes)}),
      _Draft(RecordType.member, memberId, Space.family, {'picture': Picture.photo(id)}),
    ]);
    return id;
  }

  /// Sets [memberId]'s picture to one from the pack or their initial (or back to a photo of
  /// theirs). A parent may set anyone's; a person their own, a kid when a parent allows it.
  Future<void> setPicture(String memberId, String picture) async {
    final m = member(memberId);
    if (m == null) throw const InvalidInput('That person isn\'t in the family');
    if (!Picture.valid(picture)) throw const InvalidInput('That isn\'t a picture Den knows');
    if (!canChangePicture(actor, m, family)) {
      throw PermissionDenied('${actor?.name ?? 'This screen'} can\'t change ${m.name}\'s picture');
    }
    await _commit([_Draft(RecordType.member, memberId, Space.family, {'picture': picture})]);
  }

  /// Whether [deviceId] belongs to a sitter whose last day ([Member.until]) has passed, by this
  /// device's clock: a device serving sync stops syncing with it, whether or not a parent's
  /// device has removed it yet.
  bool accessEnded(String deviceId) {
    final d = device(deviceId);
    final m = d?.member == null ? null : member(d!.member!);
    return m != null && m.accessEndedOn(todayDate());
  }

  /// Removes the devices of every sitter whose last day has passed, the usual way (a
  /// revocation naming the last change held from each, and new keys for what they held).
  /// Only a parent's own device does this, when Den opens there; anywhere else it does
  /// nothing. Returns the sitters whose devices it removed.
  Future<List<String>> endExpiredAccess() => _locked(() async {
        if (!_parentsOwnDevice) return const <String>[];
        final today = todayDate();
        final ended = <String>[];
        final owned = <String>[];
        for (final m in members) {
          if (!m.accessEndedOn(today)) continue;
          final theirs = _liveDevicesOf(m.id);
          if (theirs.isEmpty) continue;
          ended.add(m.id);
          owned.addAll(theirs);
        }
        if (owned.isEmpty) return const <String>[];
        final held = {for (final d in owned) ...spacesForDevice(d)};
        await _commitNow([for (final d in owned) _revocation(d)]);
        await _rotateNow(held);
        return ended;
      });

  /// Ends a sitter's access now: their last day becomes yesterday and their devices are
  /// removed, as [endExpiredAccess] would. To let them back in, a parent sets a later day and
  /// invites them again.
  Future<void> endAccessNow(String memberId) => _locked(() async {
        final m = member(memberId);
        if (m == null) throw const InvalidInput('That person isn\'t in the family');
        if (m.role != Role.guest) throw const InvalidInput('Only a sitter\'s access has a last day');
        final today = todayDate();
        final theirs = _liveDevicesOf(memberId);
        final held = {for (final d in theirs) ...spacesForDevice(d)};
        await _commitNow([
          if (!m.accessEndedOn(today)) _Draft(RecordType.member, memberId, Space.family, {'until': addDays(today, -1)}),
          for (final d in theirs) _revocation(d),
        ]);
        await _rotateNow(held);
      });

  /// [memberId]'s approved devices that aren't removed, besides this one.
  List<String> _liveDevicesOf(String memberId) => [
        for (final d in devices)
          if (d.member == memberId && d.approved && !d.revoked && d.id != deviceId) d.id,
      ];

  /// A parent acting on their own device: a personal one, or the hub its owner is using.
  bool get _parentsOwnDevice {
    final d = thisDevice, a = actor;
    if (d == null || a == null || !a.isParent || !isApproved) return false;
    return d.mode == DeviceMode.personal || (d.mode == DeviceMode.hub && d.member == a.id && actingVia == null);
  }

  /// The latest change that turned whether parents see [memberId]'s "Just me" items one way or
  /// the other, or null when nobody ever has: what that person's Today and History tell them.
  PrivacyChange? privacyChange(String memberId) =>
      _memo('privacy|$memberId', const {RecordType.family}, visible: false, () => _privacyChange(memberId));

  PrivacyChange? _privacyChange(String memberId) {
    final entry = 'oversight.$memberId';
    bool sees(Object? v) => (v is Map ? v['parentsSeePrivate'] : null) as bool? ?? true;
    final applied = _mat.appliedToFamily;
    for (var i = applied.length - 1; i >= 0; i--) {
      final a = applied[i];
      final c = a.change;
      if (c.type != RecordType.family) continue;
      final Object? before, after;
      if (c.fields.containsKey(entry)) {
        before = a.before[entry];
        after = c.fields[entry];
      } else if (c.fields['oversight'] is Map) {
        before = (a.before['oversight'] as Map?)?[memberId];
        after = (c.fields['oversight']! as Map)[memberId];
      } else {
        continue;
      }
      if (sees(before) == sees(after)) continue;
      return PrivacyChange(change: c.id, member: memberId, by: c.actor, at: c.hlc.millis, parentsSee: sees(after));
    }
    return null;
  }

  // ---------------------------------------------------------------- calendar feeds

  /// Subscribed ICS calendars the actor may see (parents and hubs), by label.
  List<Subscription> get subscriptions => _memo('subscriptions', const {RecordType.subscription}, () {
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
      final all = _occurrencesIn(dayStart(dates.first), dayStart(addDays(dates.last, 1)));
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
        for (final cd in _choresOn(d)) {
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
      if (_driversEcho(c)) continue;
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
      if (!want.remove(a.change.id) || !readable.contains(a.change.space) || _driversEcho(a.change)) continue;
      out.add(_historyEntry(a));
    }
    return out.reversed.toList();
  }

  /// Whether [c] writes only an event's `drivers` (an occurrence's `patch.drivers.<leg>`), saying
  /// again what the `rides` its device wrote in the change just before says
  /// ([_olderVersionsFirst]). History shows the two as one change: that one.
  bool _driversEcho(Change c) {
    final event = c.type == RecordType.event;
    if (!event && c.type != RecordType.eventException) return false;
    final legs = <String, Object?>{};
    var whole = false;
    for (final e in c.fields.entries) {
      final k = e.key;
      if (k.startsWith('_')) continue;
      if (event && k == 'drivers' && e.value is Map) {
        whole = true;
        legs.addAll(Map<String, Object?>.from(e.value as Map));
      } else if (event && k.startsWith('drivers.')) {
        legs[k.substring(8)] = e.value;
      } else if (!event && k.startsWith('patch.drivers.')) {
        legs[k.substring(14)] = e.value;
      } else {
        return false;
      }
    }
    if (legs.isEmpty && !whole) return false;
    final colon = c.id.lastIndexOf(':');
    final counter = int.tryParse(c.id.substring(colon + 1));
    if (colon < 0 || counter == null) return false;
    final before = _mat.byId('${c.id.substring(0, colon)}:${counter - 1}');
    if (before == null || before.type != c.type || before.rid != c.rid || before.space != c.space) return false;
    if (_mat.rejected.containsKey(before.id)) return false;
    final patch = before.fields['patch'];
    final rides = event ? before.fields['rides'] : before.fields['patch.rides'] ?? (patch is Map ? patch['rides'] : null);
    if (rides is! List) return false;
    final said = {for (final r in rides.reversed) if (r is Map) r['leg']: r['driver']};
    if (whole && said.length != legs.length) return false;
    for (final e in legs.entries) {
      // A leg handed back to the series: the list says the series' driver, which isn't here.
      if (!event && e.value == null) continue;
      if (!said.containsKey(e.key) || said[e.key] != (e.value == '' ? null : e.value)) return false;
    }
    return true;
  }

  static Object? _redact(String field, Object? value) {
    if (value == null) return null;
    if (field == 'signIn' && value is Map) return {'kind': value['kind']};
    if (field == 'tokenHash' || field == 'pubkey' || field == 'xpub') return '•••';
    if (field == 'recovery' && value is Map) {
      return value.containsKey('kind')
          ? {'kind': value['kind'], 'member': value['member']}
          : {'on': (value['key'] ?? value['serverKey']) != null};
    }
    // A device's invite proof says which invite and for whom; an invite's key says only that it
    // is there (it lets someone in) or was taken away.
    if (field == 'invite' && value is Map) return {'invite': value['invite'], 'member': value['member'], 'mode': value['mode']};
    if (field == 'key' && value is String) return '•••';
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

  /// Words a question asked of search carries that don't name anything.
  static const Set<String> _searchFiller = {
    'a', 'an', 'the', 'is', 'are', 'when', 'what', 'where', 'who', 'at', 'on', 'in', 'for', 'to', 'of', 'my', 'our',
    'and', 'with', 'next', 'this', 'whats', "what's", 'find',
  };

  /// Finds people, events, chores, lists and items by words, best first. A record matches when
  /// the whole query is in its title (best), in its place or notes, or when every word of the
  /// query is somewhere in it: its title, place, notes, store, list, or the people it's for (so
  /// "dentist jimmy" finds Jimmy's dentist visit, and "Jimmy" his events and chores too). A word
  /// of four letters or more also matches one a letter or two off ("socer"). Removed things,
  /// which History keeps, are left out unless [includeHistory].
  List<SearchHit> search(String query, {int limit = 50, bool includeHistory = false}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final all = searchWords(q);
    final content = [for (final w in all) if (!_searchFiller.contains(w)) w];
    final words = content.isEmpty ? all : content;
    final hits = <(int, int, SearchHit)>[];
    final seen = <String>{};
    int rank(String text) {
      final t = text.toLowerCase();
      if (t == q) return 0;
      if (t.startsWith(q)) return 1;
      if (t.split(RegExp(r'\s+')).any((w) => w.startsWith(q))) return 2;
      return t.contains(q) ? 3 : -1;
    }

    void add(int typeOrder, String text, SearchHit hit, [List<String> also = const [], List<String> people = const []]) {
      var r = rank(text);
      for (final extra in also) {
        final ar = rank(extra);
        if (ar >= 0 && (r < 0 || ar + 4 < r)) r = ar + 4;
      }
      if (r < 0 && words.isNotEmpty) {
        // People's names count from three letters on: "ma" typed on the way to "Maya" shouldn't
        // list everything of hers yet.
        final named = words.every((w) => w.length >= 3) ? people : const <String>[];
        final hay = searchWords([text, ...also, ...named].join(' ').toLowerCase());
        final exact = words.every((w) => hay.any((h) => h.startsWith(w) || (w.length >= 3 && h.contains(w))));
        if (exact) {
          r = 8;
        } else if (words.every((w) => hay.any((h) => h.startsWith(w) || nearlySame(w, h)))) {
          r = 10;
        }
      }
      if (r < 0 || !seen.add('${hit.type}/${hit.id}')) return;
      hits.add((r, typeOrder, hit));
    }

    List<String> names(Iterable<String> ids) => [for (final id in ids) ?member(id)?.name];
    for (final m in members) {
      add(0, m.name, SearchHit(type: RecordType.member, id: m.id, title: m.name));
    }
    final now = _now();
    for (final e in events) {
      final next = seriesStarts(e, _zone, notBefore: now).firstOrNull ?? e.start;
      add(1, e.title, SearchHit(type: RecordType.event, id: e.id, title: e.title, detail: e.location.isEmpty ? null : e.location, when: next),
          [e.location, e.notes], names(e.assignees));
    }
    for (final c in chores) {
      final owners = switch (c.owner) {
        OwnerMember(:final id) => [id],
        OwnerRotation(:final ids) => ids,
        OwnerAnyone() => const <String>[],
      };
      add(2, c.title, SearchHit(type: RecordType.chore, id: c.id, title: c.title), [c.notes], names(owners));
    }
    for (final l in lists) {
      add(3, l.list.title, SearchHit(type: RecordType.list, id: l.list.id, title: l.list.title));
      for (final i in l.items) {
        add(4, i.text, SearchHit(type: RecordType.item, id: i.id, title: i.text, detail: l.list.title), [i.store ?? ''], [l.list.title]);
      }
    }
    if (includeHistory) {
      final readable = readableSpaces;
      for (final a in _mat.applied.reversed) {
        final c = a.change;
        if (!readable.contains(c.space) || a.title.isEmpty) continue;
        if (!const {RecordType.event, RecordType.chore, RecordType.list, RecordType.item}.contains(c.type)) continue;
        add(12, a.title, SearchHit(type: c.type, id: c.rid, title: a.title, detail: 'History', when: c.hlc.millis));
      }
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
    final today = todayDate();
    final wall = wallTime(_zone, _now());
    final nowMinutes = wall.hour * 60 + wall.minute;
    return List.of(_memo('gaps|$start|$end|$today|$nowMinutes', const {
      RecordType.event, RecordType.eventException, RecordType.chore, RecordType.completion, //
      RecordType.member, RecordType.family,
    }, () => _gapsNow(start, end)));
  }

  List<Gap> _gapsNow(int start, int end) {
    final occ = _occurrencesIn(start, end);
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
    // [occ] is sorted by start, so the events overlapping timed[i] that start no earlier are the
    // run right after it: a sweep, not every pair.
    for (var i = 0; i < timed.length; i++) {
      for (var j = i + 1; j < timed.length && timed[j].start < timed[i].end; j++) {
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
    out.addAll(_busyDrivers(occ));
    final today = todayDate();
    if (dayStart(today) < end && dayStart(addDays(today, 1)) > start) {
      for (final cd in _choresOn(today)) {
        if (cd.date == today && cd.owner == null && !cd.done) {
          out.add(Gap(kind: GapKind.unowned, message: '${cd.chore.title} is up for grabs', occurrences: const []));
        }
      }
    }
    return out;
  }

  /// How close two rides by one driver may be, from different places: a leg is driven at its
  /// event's start (to) or end (from).
  static const int rideGap = 30 * 60 * 1000;

  /// Someone driving two places at once: two ride legs of different occurrences, less than
  /// [rideGap] apart, with the same driver, unless both events are at the same place.
  List<Gap> _busyDrivers(List<Occurrence> occ) {
    final legs = <(String, int, Occurrence)>[
      for (final o in occ)
        if (!o.allDay)
          for (final r in o.rides)
            if (r.driver != null) (r.driver!, r.leg == 'from' ? o.end : o.start, o),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    final out = <Gap>[];
    final seen = <String>{};
    String key(Occurrence o) => '${o.event.id}@${o.seriesStart}';
    for (var i = 0; i < legs.length; i++) {
      for (var j = i + 1; j < legs.length && legs[j].$2 - legs[i].$2 < rideGap; j++) {
        final (driver, _, a) = legs[i];
        final (other, _, b) = legs[j];
        if (driver != other || key(a) == key(b)) continue;
        final place = a.location.trim().toLowerCase();
        if (place.isNotEmpty && place == b.location.trim().toLowerCase()) continue;
        final pair = [key(a), key(b)]..sort();
        if (!seen.add('$driver|${pair.join('|')}')) continue;
        out.add(Gap(
          kind: GapKind.driverBusy,
          message: '${member(driver)?.name ?? 'Someone'} is driving two places at once: ${a.title} and ${b.title}',
          occurrences: [a, b],
          members: [driver],
        ));
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
    for (final x in _exceptions.values.expand((byEvent) => byEvent.values).expand((m) => m.values)) {
      for (final m in (x.patch['reminders'] as List? ?? const [])) {
        maxLead = math.max(maxLead, (m as num).toInt());
      }
    }
    for (final o in _occurrencesIn(from, to + maxLead * 60000 + 1)) {
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
      for (final cd in _choresOn(d)) {
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
        final toCheck = <Change>[];
        for (final c in candidates.values) {
          if (_pubkeys[c.device] == null) {
            _pending[c.id] = c;
          } else {
            toCheck.add(c);
          }
        }
        // Checked as a batch: in worker isolates where there are any, else in slices that let
        // the page draw in between.
        final checked = await checkChanges(
          toCheck,
          pubkeys: [for (final c in toCheck) _pubkeys[c.device]],
          hash: _snapshots,
        );
        for (var i = 0; i < toCheck.length; i++) {
          final c = toCheck[i], h = checked[i];
          // A recovery or invite proof is checked with the signature: signed by the key it names.
          if (h == null || !await recoveryProofHolds(c, familyId) || !await inviteProofHolds(c, familyId) || !await accountProofHolds(c, familyId)) {
            rejected[c.id] = 'The signature doesn\'t verify';
          } else {
            accepted.add(c);
            if (_snapshots) _hashes[c.id] = h;
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
          _noteAdded(accepted);
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
        _maybeSnapshot();
        return IngestResult(
          added: accepted.length,
          duplicate: duplicate,
          invalid: invalid,
          rejected: rejected,
          pending: _pending.length,
        );
      });

  /// The spaces the given device should hold, per its owner, mode and the family's policy.
  Set<String> spacesForDevice(String deviceId) => _memo('spaces|$deviceId', _whoReadsWhat, visible: false, () {
        final d = device(deviceId);
        if (d == null || !d.approved || d.revoked) return const <String>{};
        final owner = d.member == null ? null : member(d.member!);
        return Set<String>.unmodifiable(spacesFor(device: d, owner: owner, family: family, members: members));
      });

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

  /// A draft that writes an event's `drivers` (an occurrence's `patch.drivers.<leg>`) with other
  /// fields, as two: the others, then the drivers. An older version refuses a whole change with a
  /// field it doesn't know, so what it can read (the `rides` written for it, a new event, an
  /// occurrence moved with its series) comes in a change of its own; and `drivers` coming after
  /// that `rides` is how readers tell it from a `rides` an older version wrote
  /// ([Event.readsDrivers], [EventException.ridesWhole]).
  static List<_Draft> _olderVersionsFirst(_Draft d) {
    final event = d.type == RecordType.event;
    if (d.hlc != null || (!event && d.type != RecordType.eventException)) return [d];
    final rest = <String, Object?>{}, drivers = <String, Object?>{};
    for (final e in d.fields.entries) {
      final k = e.key;
      if (event ? k == 'drivers' || k.startsWith('drivers.') : k.startsWith('patch.drivers.')) {
        drivers[k] = e.value;
      } else if (!event && k == 'patch' && e.value is Map) {
        final patch = Map<String, Object?>.from(e.value as Map);
        for (final key in [...patch.keys.where((key) => key.startsWith('drivers.'))]) {
          drivers['patch.$key'] = patch.remove(key);
        }
        rest[k] = patch;
      } else {
        rest[k] = e.value;
      }
    }
    if (drivers.isEmpty || rest.isEmpty) return [d];
    return [
      _Draft(d.type, d.rid, d.space, rest, actor: d.actor, setsActor: d.setsActor),
      _Draft(d.type, d.rid, d.space, drivers, actor: d.actor, setsActor: d.setsActor),
    ];
  }

  Future<List<Change>> _commitNow(List<_Draft> drafts) async {
    if (drafts.isEmpty) return const [];
    final made = <Change>[];
    var counter = _counter;
    final acting = actor?.id;
    final via = thisDevice?.mode == DeviceMode.hub ? actingVia : null;
    final zoned = Zone.current[_origins];
    final origin = zoned is CaptureOrigin ? zoned : null;
    try {
      for (final d in drafts.expand(_olderVersionsFirst)) {
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
        final bytes = unsigned.signedBytes;
        final signed = Change(
          id: unsigned.id,
          space: unsigned.space,
          hlc: unsigned.hlc,
          type: unsigned.type,
          rid: unsigned.rid,
          fields: unsigned.fields,
          device: deviceId,
          actor: unsigned.actor,
          sig: await _keys.sign(bytes),
        );
        final invalid = _mat.add([signed]);
        if (invalid.isNotEmpty) throw PermissionDenied(invalid.values.first);
        made.add(signed);
        if (_snapshots) _hashes[signed.id] = changeHash(signed, bytes);
      }
      await _storage.appendChanges(made);
    } on Object {
      _mat.remove([for (final c in made) c.id]);
      for (final c in made) {
        _hashes.remove(c.id);
      }
      rethrow;
    }
    _counter = counter;
    await _saveMeta();
    _maybeSnapshot();
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

  /// Memoized views kept at most; the least recently used goes first.
  static const int _maxMemos = 256;

  /// [build]'s value, kept until a record of one of [types] changes. A [visible] view reads only
  /// what the actor may see, so it is kept through changes in spaces they can't read and worked
  /// out again when who is acting, or what they may read, changes.
  T _memo<T>(String key, Set<String> types, T Function() build, {bool visible = true}) {
    final store = _mat.store;
    final actorId = actor?.id;
    final kept = _memos.remove(key);
    if (kept != null && kept.storeVersion == store.version && kept.actor == actorId) {
      _memos[key] = kept;
      return kept.value as T;
    }
    final readable = visible ? readableSpaces : null;
    var version = 0;
    if (readable != null) {
      version = store.versionOf(types, readable);
    } else {
      for (final t in types) {
        version += store.versionOfType(t);
      }
    }
    if (kept != null &&
        kept.epoch == store.epoch &&
        kept.actor == actorId &&
        identical(kept.readable, readable) &&
        kept.version == version) {
      kept.storeVersion = store.version;
      _memos[key] = kept;
      return kept.value as T;
    }
    final value = build();
    _memos[key] = _Memo(store.version, store.epoch, actorId, readable, version, value);
    if (_memos.length > _maxMemos) _memos.remove(_memos.keys.first);
    return value;
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
  /// keeping ids: new copies in the target space, removals in the old one. An event's copy reads
  /// the rides it has now, or [rides].
  List<_Draft> _moveDrafts(Entry entry, String target, Map<String, Object?> patch, String childType, String parentField,
      {List<Ride>? rides}) {
    Map<String, Object?> copyOf(Entry e) => {
          for (final f in e.fields.entries)
            if (!f.key.startsWith('_')) f.key: f.value,
          if (e.type == RecordType.event) ..._eventRidesToCopy(e, rides),
          if (e.type == RecordType.eventException && e.fields['patch'] is Map)
            'patch': _patchToCopy(EventException(e.rec), rides ?? Event(entry.rec).rides),
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

/// One memoized view and what it was worked out from.
class _Memo {
  _Memo(this.storeVersion, this.epoch, this.actor, this.readable, this.version, this.value);

  /// [RecordStore.version] when last found current: unchanged means nothing at all changed.
  int storeVersion;
  final int epoch;
  final String? actor;
  final Set<String>? readable;
  final int version;
  final Object? value;
}

/// One event's occurrences in the windows asked for lately, while its changed occurrences and the
/// family's time zone stay as they were (the event itself is the cache's key).
class _EventOccurrences {
  _EventOccurrences(this._exceptions, this._zone)
      : _recs = _exceptions.isEmpty ? const {} : {for (final e in _exceptions.entries) e.key: e.value.rec};

  final Map<int, EventException> _exceptions;
  final Map<int, Rec> _recs;
  final String _zone;
  final List<(int, int, List<Occurrence>)> _windows = [];

  /// Windows kept per event.
  static const int _keep = 6;

  bool holds(Map<int, EventException> exceptions, String zone) {
    if (zone != _zone) return false;
    if (identical(exceptions, _exceptions)) return true;
    if (exceptions.length != _recs.length) return false;
    for (final x in exceptions.entries) {
      if (!identical(_recs[x.key], x.value.rec)) return false;
    }
    return true;
  }

  List<Occurrence>? window(int start, int end) {
    for (final w in _windows) {
      if (w.$1 == start && w.$2 == end) return w.$3;
    }
    return null;
  }

  List<Occurrence> keep(int start, int end, List<Occurrence> found) {
    if (_windows.length >= _keep) _windows.removeAt(0);
    _windows.add((start, end, found.isEmpty ? const <Occurrence>[] : found));
    return found;
  }
}
