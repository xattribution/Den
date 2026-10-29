import 'dart:async';
import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:stream_channel/stream_channel.dart';

import 'change_index.dart';
import 'invite.dart';
import 'relay_client.dart';
import 'seal.dart';
import 'session.dart';
import 'spoken_code.dart';
import 'util.dart';

/// Where a peer connection is in its life.
enum PeerPhase {
  /// The peer isn't an approved device (yet): only pairing messages flow.
  pairing,

  /// Exchanging what each side lacks.
  syncing,

  /// Caught up; live changes flow as they're made.
  live,

  /// The session ended.
  closed,
}

/// How far a join request has come, on the joining device.
enum JoinStage {
  /// Proving possession of the QR secret or spoken code.
  proving,

  /// The inviting side accepted the request; a parent has to approve it.
  waitingForApproval,

  /// Approved; receiving space keys and the family's data.
  syncing,

  /// Approved and caught up.
  done,

  /// Refused: wrong code, used or expired invite, or a parent declined.
  rejected,

  /// The connection ended before the join finished.
  failed,
}

/// A join was refused or broke off.
class JoinException implements Exception {
  /// Creates the exception.
  JoinException(this.reason);

  /// Short reason code such as `bad-proof`, `revoked` or `closed`.
  final String reason;

  @override
  String toString() => 'JoinException: $reason';
}

/// A device waiting, on a live session, for a parent to approve it.
class PendingJoin {
  PendingJoin._({
    required this.deviceId,
    required this.name,
    required this.kind,
    required this.requestedMode,
    required this.requestedMember,
    required this.matchingWords,
    required this.via,
    required this.since,
    required SyncPeer peer,
  }) : _peer = peer;

  /// The joining device's id.
  final String deviceId;

  /// The name it gave itself, for the "Approve this device?" prompt.
  final String name;

  /// What it says it is.
  final DeviceKind kind;

  /// The mode it asked for; the approving parent decides the real one.
  final DeviceMode requestedMode;

  /// The member it asked to belong to, if any; the approving parent decides the real one.
  final String? requestedMember;

  /// The three words both screens show. For a spoken code, approve only if they match.
  final List<String> matchingWords;

  /// `qr` or `code`. A device whose earlier request is still waiting asks again the same way,
  /// with a new invite or code.
  final String via;

  /// When the request arrived.
  final DateTime since;

  final SyncPeer _peer;

  /// The session carrying the request.
  SyncPeer get peer => _peer;
}

/// The joining device's view of a join request.
class JoinAttempt {
  JoinAttempt._(this.peer, this.via) {
    _completed.future.ignore();
  }

  /// The session to the inviting device.
  final SyncPeer peer;

  /// `qr` or `code`.
  final String via;

  final StreamController<JoinStage> _stages = StreamController.broadcast();
  final Completer<void> _completed = Completer();
  JoinStage _stage = JoinStage.proving;
  String? _code;
  Invite? _invite;
  _JoinRequest? _request;

  /// The three words to compare with the inviting screen.
  List<String> get matchingWords => peer.session.matchingWords;

  /// The current stage.
  JoinStage get stage => _stage;

  /// Stage changes.
  Stream<JoinStage> get stages => _stages.stream;

  /// Completes once approved and caught up; fails with [JoinException] otherwise.
  Future<void> get completed => _completed.future;

  /// Abandons the request.
  Future<void> cancel() => peer.close();

  void _set(JoinStage stage) {
    if (_stage == stage || _stage == JoinStage.done || _stage == JoinStage.rejected || _stage == JoinStage.failed) {
      return;
    }
    _stage = stage;
    if (!_stages.isClosed) _stages.add(stage);
    if (stage == JoinStage.done) {
      if (!_completed.isCompleted) _completed.complete();
      unawaited(_stages.close());
    }
  }

  void _fail(JoinStage stage, String reason) {
    if (_stage == JoinStage.done || _stage == JoinStage.rejected || _stage == JoinStage.failed) return;
    _stage = stage;
    if (!_stages.isClosed) _stages.add(stage);
    if (!_completed.isCompleted) _completed.completeError(JoinException(reason));
    unawaited(_stages.close());
  }
}

class _JoinRequest {
  _JoinRequest(this.deviceName, this.kind, this.mode, this.memberId);
  final String deviceName;
  final DeviceKind kind;
  final DeviceMode mode;
  final String? memberId;
}

/// Runs Den's sync protocol for one [Den]: the server role (hub `/ws`, relay tunnel streams,
/// devices in hub mode), the client role, and pairing on both sides.
///
/// Every connection is a [Session]. Approved peers exchange `have {vv, keys}`, answer with
/// `changes {list, done}`, then `push {list}` live changes; each side sends only spaces its
/// replica says the peer may hold (`den.spacesForDevice`). A peer that isn't an approved device
/// gets nothing but pairing messages until a parent approves it.
class SyncNode {
  /// Creates a node over [den]. Starts listening to [Den.onChange] at once.
  SyncNode(
    this.den, {
    InviteBook? invites,
    CodeBook? codes,
    this.handshakeTimeout = const Duration(seconds: 20),
    this.pairingTimeout = const Duration(minutes: 15),
    this.unpairedTimeout = const Duration(seconds: 30),
    this.maxPeers = 256,
    this.maxPairingPeers = 8,
  })  : invites = invites ?? InviteBook(),
        codes = codes ?? CodeBook() {
    _changes = den.onChange.listen((_) {
      _scheduleChangeScan();
      _scheduleKeyChecks();
    });
    _keyMarks = _currentKeyMarks();
    _keyWatch = Timer.periodic(const Duration(seconds: 5), (_) => _checkKeyEpochs());
  }

  /// The engine this node syncs.
  final Den den;

  /// Live QR invites this device accepts.
  final InviteBook invites;

  /// Live spoken codes this device accepts.
  final CodeBook codes;

  /// How long a handshake may take.
  final Duration handshakeTimeout;

  /// How long a peer that proved an invite or code may stay connected waiting for approval.
  final Duration pairingTimeout;

  /// How long a peer that isn't an approved device may stay connected before it proves an
  /// invite or code.
  final Duration unpairedTimeout;

  /// Most simultaneous sessions accepted by [serve].
  final int maxPeers;

  /// Most of those that may come from devices that aren't approved (pairing, or waiting for a
  /// parent), counting handshakes in progress, so strangers can't take the approved devices'
  /// places.
  final int maxPairingPeers;

  final Set<SyncPeer> _peers = {};
  final List<PendingJoin> _pending = [];
  final StreamController<List<PendingJoin>> _pendingChanges = StreamController.broadcast();
  final StreamController<SyncPeer> _peerEvents = StreamController.broadcast();
  final ChangeIndex _index = ChangeIndex();
  final SerialQueue _queue = SerialQueue();
  late final StreamSubscription<Set<String>> _changes;
  bool _indexBuilt = false;
  bool _scanScheduled = false;
  bool _closed = false;
  Set<String> _mySpaces = const {};
  Map<String, String> _keyMarks = const {};
  late final Timer _keyWatch;
  int _keyPushHolds = 0;
  int _pairingHandshakes = 0;

  /// Devices turned away on this node: refused from then on, even with a new invite or code.
  final Set<String> _declined = {};

  /// Connected peers.
  Iterable<SyncPeer> get peers => List.unmodifiable(_peers);

  /// Each peer as it connects.
  Stream<SyncPeer> get peerConnected => _peerEvents.stream;

  /// Devices on a live session waiting for a parent's approval. Devices that asked earlier and
  /// disconnected are in `den.pendingDevices`.
  List<PendingJoin> get pendingJoins => List.unmodifiable(_pending);

  /// [pendingJoins] after every change.
  Stream<List<PendingJoin>> get pendingJoinsChanges => _pendingChanges.stream;

  // ------------------------------------------------------------------ roles

  /// Serves one incoming connection (a hub's `/ws` WebSocket, a relay tunnel stream, a
  /// rendezvous pipe) until it closes.
  Future<void> serve(StreamChannel<dynamic> channel, {FrameEncoding? encoding}) async {
    if (_closed) {
      unawaited(channel.sink.close());
      return;
    }
    final Session session;
    var pairing = false;
    try {
      session = await Session.accept(
        channel,
        keys: den.keys,
        familyId: den.familyId,
        admit: (hello) {
          if (!_admit(hello)) return false;
          if (!_approvedHello(hello)) {
            pairing = true;
            _pairingHandshakes++;
          }
          return true;
        },
        encoding: encoding,
        timeout: handshakeTimeout,
      );
    } on SessionException {
      return;
    } finally {
      if (pairing) _pairingHandshakes--;
    }
    final peer = _attach(session);
    peer._start();
    await peer.closed;
  }

  /// Opens a client session over [channel] to an approved device of this family (normally the
  /// hub). [expectDevice] / [expectPubkey] pin the server; without a pin the server must already
  /// be known to this replica as an approved device.
  Future<SyncPeer> connect(
    StreamChannel<dynamic> channel, {
    String? expectDevice,
    String? expectPubkey,
    FrameEncoding? encoding,
  }) async {
    if (!den.hasFamily) throw StateError('this device has no family yet; join first');
    final session = await Session.connect(
      channel,
      keys: den.keys,
      familyId: den.familyId,
      expectDevice: expectDevice,
      expectPubkey: expectPubkey,
      encoding: encoding,
      timeout: handshakeTimeout,
    );
    final peer = _attach(session);
    peer._start();
    return peer;
  }

  /// Joins the family in a scanned QR [invite] over [channel], which must reach the inviting
  /// device (see [openInviteChannel]). Writes this device's join request with `den.requestJoin`
  /// first, unless it already exists.
  Future<JoinAttempt> joinWithInvite(
    StreamChannel<dynamic> channel,
    Invite invite, {
    required String deviceName,
    required DeviceKind kind,
    DeviceMode mode = DeviceMode.personal,
    String? memberId,
    FrameEncoding? encoding,
  }) async {
    if (!den.hasFamily) {
      await den.requestJoin(
        familyId: invite.familyId,
        founderPubkey: invite.founderPubkey,
        deviceName: deviceName,
        kind: kind,
        mode: mode,
        memberId: memberId,
      );
    } else if (den.familyId != invite.familyId) {
      throw StateError('this device belongs to another family');
    }
    final session = await Session.connect(
      channel,
      keys: den.keys,
      familyId: invite.familyId,
      expectDevice: invite.inviterDevice,
      expectPubkey: invite.inviterPubkey,
      encoding: encoding,
      timeout: handshakeTimeout,
    );
    final peer = _attach(session);
    final attempt = JoinAttempt._(peer, 'qr').._invite = invite;
    peer._join = attempt;
    peer._start();
    await peer._send({'t': 'pair', 'kind': 'qr', 'proof': await invite.proofFor(den.keys.pubkey)});
    await peer._send({'t': 'join', 'changes': _ownJoinChanges()});
    return attempt;
  }

  /// Joins with a spoken [code] over [channel] (usually a relay rendezvous at
  /// [codeRendezvousSlot], or a hub found on the LAN). The family comes from the inviting side
  /// once it proves it knows the code; both screens then show [JoinAttempt.matchingWords].
  Future<JoinAttempt> joinWithCode(
    StreamChannel<dynamic> channel,
    String code, {
    required String deviceName,
    required DeviceKind kind,
    DeviceMode mode = DeviceMode.personal,
    String? memberId,
    FrameEncoding? encoding,
  }) async {
    final normalized = normalizeCode(code);
    if (normalized == null) throw const FormatException('Not a spoken code');
    final session = await Session.connect(
      channel,
      keys: den.keys,
      familyId: den.familyId,
      encoding: encoding,
      timeout: handshakeTimeout,
    );
    final peer = _attach(session);
    final attempt = JoinAttempt._(peer, 'code')
      .._code = normalized
      .._request = _JoinRequest(deviceName, kind, mode, memberId);
    peer._join = attempt;
    peer._start();
    await peer._send({
      't': 'pair',
      'kind': 'code',
      'proof': await joinerCodeProof(normalized, session.transcriptHash, den.keys.pubkey),
    });
    return attempt;
  }

  // ------------------------------------------------------------------ inviting

  /// Creates and starts accepting a QR invite from this device.
  Future<Invite> createInvite({
    List<Uri> hubs = const [],
    Uri? relay,
    Duration validFor = const Duration(hours: 1),
  }) async {
    final familyId = den.familyId;
    final family = den.family;
    if (familyId == null || family == null) throw StateError('no family');
    final founder = family.founderDevice == den.deviceId ? den.keys.pubkey : den.device(family.founderDevice)?.pubkey;
    if (founder == null || founder.isEmpty) throw StateError('founding device unknown');
    final invite = Invite.create(
      familyId: familyId,
      founderPubkey: founder,
      inviterDevice: den.deviceId,
      inviterPubkey: den.keys.pubkey,
      hubs: hubs,
      relay: relay,
      validFor: validFor,
    );
    invites.add(invite);
    return invite;
  }

  /// Creates an invite naming [hubDevice], this family's hub, as the inviting device, for a
  /// joiner the hub admits on this device's behalf. Hand it to the hub with [InviteGrant.sign];
  /// this device doesn't accept it itself.
  Invite createHubInvite(
    String hubDevice, {
    List<Uri> hubs = const [],
    Uri? relay,
    Duration validFor = const Duration(minutes: 15),
  }) {
    final familyId = den.familyId;
    final family = den.family;
    if (familyId == null || family == null) throw StateError('no family');
    final hub = den.device(hubDevice);
    if (hub == null || hub.mode != DeviceMode.hub || !hub.approved || hub.revoked) {
      throw StateError('that device isn\'t this family\'s hub');
    }
    final founder = family.founderDevice == den.deviceId ? den.keys.pubkey : den.device(family.founderDevice)?.pubkey;
    if (founder == null || founder.isEmpty) throw StateError('founding device unknown');
    return Invite.create(
      familyId: familyId,
      founderPubkey: founder,
      inviterDevice: hubDevice,
      inviterPubkey: hub.pubkey,
      hubs: hubs,
      relay: relay,
      validFor: validFor,
    );
  }

  /// Hub side: checks [grant] for [context] (see [InviteGrant.problem]) and starts accepting
  /// its invite. Returns null when accepted, else the reason it was refused.
  Future<String?> acceptInviteGrant(InviteGrant grant, {required String context}) async {
    final problem = await grant.problem(den, expectedContext: context);
    if (problem == null) invites.add(grant.invite);
    return problem;
  }

  /// Issues a spoken code this device accepts for the next 10 minutes.
  SpokenCode createSpokenCode() => codes.issue();

  /// Waits at a relay rendezvous [slot] for one joiner and serves it.
  Future<void> hostRendezvous(Uri relay, String slot, {ChannelConnector? connector, Duration? timeout}) async {
    final channel = await rendezvous(relay, slot, host: true, connector: connector, timeout: timeout);
    await serve(channel);
  }

  /// Approves a pending device as a parent on this device (`den.approveDevice`). The session
  /// then receives its space keys and a full sync.
  Future<void> approve(PendingJoin join, {String? member, DeviceMode? mode}) =>
      den.approveDevice(join.deviceId, member: member, mode: mode);

  /// Turns a pending device away, closes its session, and refuses it from then on, even with a
  /// new invite or code. Where this device may (a parent's own device), it also revokes the
  /// request (`den.revokeDevice`), which refuses the device on every replica and survives
  /// restarts.
  Future<void> decline(PendingJoin join) async {
    _declined.add(join.deviceId);
    final peer = join._peer;
    _removePending(peer);
    if (!peer.session.isClosed) {
      await peer._send({'t': 'join_rejected', 'reason': 'declined'}).catchError((Object _) {});
      await peer.close();
    }
    final d = den.device(join.deviceId);
    if (d != null && !d.approved && !d.revoked) {
      try {
        await den.revokeDevice(join.deviceId);
      } on Object {
        // A hub nobody owns can't revoke; it still refuses the device itself.
      }
    }
  }

  /// Whether [deviceId] was declined or removed: no invite or code brings it back.
  bool _refused(String deviceId) => _declined.contains(deviceId) || (den.device(deviceId)?.revoked ?? false);

  // ------------------------------------------------------------------ ingest

  /// Ingests changes that arrived outside a session (the relay mailbox) and forwards the new
  /// ones to connected peers.
  Future<IngestResult?> ingestExternal(List<Change> changes) => _ingestFrom(null, changes);

  // ------------------------------------------------------------------ space keys

  /// Sends peers the newest space keys they may hold and lack. Den writes trigger this on their
  /// own, and space-key epochs are checked every few seconds; call it after changing keys with
  /// `den.setSpaceKey` directly so peers get them at once.
  void keysChanged() => _scheduleChangeScan();

  /// Runs [task] with key pushes to peers held back, then sends what changed. Used while a
  /// relay mailbox round stores newly delivered keys before ingesting the changes that came
  /// with them (a revocation among them), so a newer key is never forwarded to a device this
  /// replica doesn't know is revoked yet.
  Future<T> withKeyPushHeld<T>(Future<T> Function() task) async {
    _keyPushHolds++;
    try {
      return await task();
    } finally {
      _keyPushHolds--;
      _scheduleChangeScan();
    }
  }

  /// The key in use per space, as `"<epoch>:<hash>"`: a change of either (a rotation, or another
  /// parent's key winning the same epoch) is passed on.
  Map<String, String> _currentKeyMarks() {
    final spaces = <String>{..._spacesFor(den.deviceId), ..._index.spaces, ..._keyMarks.keys};
    return {
      for (final s in spaces)
        if (_keyIn(s) case final k?) s: '${k.epoch}:${k.hash}',
    };
  }

  SpaceKey? _keyIn(String space) {
    try {
      return den.currentSpaceKey(space);
    } on Object {
      return null;
    }
  }

  // Rotations land in the engine's metadata after the revocation's change event, with no
  // event of their own; look again shortly after every change.
  void _scheduleKeyChecks() {
    for (final ms in const [100, 500, 2000]) {
      Timer(Duration(milliseconds: ms), _checkKeyEpochs);
    }
  }

  void _checkKeyEpochs() {
    if (_closed) return;
    final now = _currentKeyMarks();
    if (now.length != _keyMarks.length || now.entries.any((e) => _keyMarks[e.key] != e.value)) {
      _scheduleChangeScan();
    }
  }

  /// Stops every session and listener.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _keyWatch.cancel();
    await _changes.cancel();
    await Future.wait([for (final p in List.of(_peers)) p.close()]);
    await _pendingChanges.close();
    await _peerEvents.close();
  }

  // ------------------------------------------------------------------ internals

  bool _admit(ClientHello hello) {
    if (_closed || !den.hasFamily) return false;
    if (hello.family != null && hello.family != den.familyId) return false;
    if (_peers.length >= maxPeers) return false;
    if (_approvedHello(hello)) return true;
    final waiting = _peers.where((p) => !p.isClient && p._phase == PeerPhase.pairing).length;
    return waiting + _pairingHandshakes < maxPairingPeers;
  }

  /// Whether a client hello comes from an approved, unrevoked device of this family with its key.
  bool _approvedHello(ClientHello hello) {
    if (hello.family == null) return false;
    final d = den.device(hello.device);
    return d != null && d.approved && !d.revoked && d.pubkey == hello.pubkey;
  }

  SyncPeer _attach(Session session) {
    final peer = SyncPeer._(this, session);
    _peers.add(peer);
    unawaited(session.done.then((_) => _detach(peer)));
    if (!_peerEvents.isClosed) _peerEvents.add(peer);
    return peer;
  }

  void _detach(SyncPeer peer) {
    _peers.remove(peer);
    _removePending(peer);
    peer._onClosed();
  }

  void _addPending(PendingJoin join) {
    _pending.removeWhere((p) => p.deviceId == join.deviceId);
    _pending.add(join);
    if (!_pendingChanges.isClosed) _pendingChanges.add(pendingJoins);
  }

  void _removePending(SyncPeer peer) {
    final before = _pending.length;
    _pending.removeWhere((p) => identical(p._peer, peer));
    if (_pending.length != before && !_pendingChanges.isClosed) _pendingChanges.add(pendingJoins);
  }

  List<Map<String, Object?>> _ownJoinChanges() => [
        for (final c in den.changesSince(const {}))
          if (c.device == den.deviceId) c.toJson(),
      ];

  Set<String> _spacesFor(String deviceId) {
    try {
      return den.spacesForDevice(deviceId);
    } on Object {
      return const {};
    }
  }

  void _ensureIndex() {
    if (_indexBuilt) return;
    _index.clear();
    for (final c in den.changesSince(const {})) {
      _index.add(c);
    }
    _indexBuilt = true;
    _mySpaces = _spacesFor(den.deviceId);
  }

  /// Indexes changes written locally since the last look.
  void _scanLocal() {
    _ensureIndex();
    for (final c in den.changesSince(_index.maxByAuthor)) {
      _index.add(c);
    }
  }

  Future<IngestResult?> _ingestFrom(SyncPeer? source, List<Change> changes) => _queue.run(() async {
        _ensureIndex();
        final seen = <String>{};
        final fresh = [
          for (final c in changes)
            if (!_index.contains(c) && seen.add(c.id)) c,
        ];
        if (fresh.isEmpty) return null;
        final result = await den.ingest(fresh);
        final List<Change> held;
        if (result.rejected.isEmpty && result.pending == 0) {
          fresh.forEach(_index.add);
          held = fresh;
        } else {
          // Some were refused (bad signature) or are waiting for their author's device record:
          // re-read what the log really holds so summaries never claim them.
          _indexBuilt = false;
          _ensureIndex();
          held = [
            for (final c in fresh)
              if (_index.contains(c)) c,
          ];
        }
        for (final peer in List.of(_peers)) {
          if (!identical(peer, source)) peer._forward(held);
        }
        return result;
      });

  void _scheduleChangeScan() {
    if (_scanScheduled || _closed) return;
    _scanScheduled = true;
    Timer.run(() {
      _scanScheduled = false;
      if (_closed) return;
      unawaited(_queue.run(_afterChange).catchError((Object _) {}));
    });
  }

  Future<void> _afterChange() async {
    _scanLocal();
    final mine = _spacesFor(den.deviceId);
    final spacesChanged = !_sameSet(mine, _mySpaces);
    _mySpaces = mine;
    for (final peer in List.of(_peers)) {
      await peer._onDenChanged(mySpacesChanged: spacesChanged);
    }
    // Keys go after the changes above, so a peer always has a revocation before the keys it
    // caused, and never forwards those keys to the revoked device.
    if (_keyPushHolds > 0) return;
    _keyMarks = _currentKeyMarks();
    for (final peer in List.of(_peers)) {
      await peer._sendMissingKeys();
    }
  }
}

bool _sameSet(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

const int _batchBytes = 256 * 1024;
const int _batchChanges = 2000;

/// One session with another device, running the sync protocol (and pairing, for a device not
/// yet approved). Created by [SyncNode].
class SyncPeer {
  SyncPeer._(this._node, this.session) {
    _live.future.ignore();
  }

  final SyncNode _node;

  /// The encrypted session underneath.
  final Session session;

  final SerialQueue _inbox = SerialQueue();
  final StreamController<PeerPhase> _phases = StreamController.broadcast();
  final Completer<void> _live = Completer();
  final Map<String, Map<String, int>> _known = {};
  /// The newest key epoch the peer holds per space, and the hashes of the keys it holds for it.
  final Map<String, int> _peerEpochs = {};
  final Map<String, Set<String>> _peerHashes = {};
  StreamSubscription<Map<String, Object?>>? _subscription;
  PeerPhase _phase = PeerPhase.pairing;
  Set<String> _allowed = const {};
  bool _sentHave = false;
  bool _initialSent = false;
  bool _haveHandled = false;
  bool _initialReceived = false;
  bool _trusted = false;
  bool _awaitingApproval = false;
  String? _pairedVia;
  String? _closeReason;
  Timer? _pairingTimer;
  JoinAttempt? _join;

  /// Client side: waiting for a server this device doesn't know yet to show its record.
  bool _vouching = false;
  final List<Map<String, Object?>> _deferred = [];

  Den get _den => _node.den;

  /// The other device's id, verified in the handshake.
  String get deviceId => session.peerDevice;

  /// The other device's Ed25519 key.
  String get pubkey => session.peerPubkey;

  /// Whether this side opened the connection.
  bool get isClient => session.isClient;

  /// The three words for comparing screens.
  List<String> get matchingWords => session.matchingWords;

  /// The current phase.
  PeerPhase get phase => _phase;

  /// Phase changes.
  Stream<PeerPhase> get phases => _phases.stream;

  /// Completes when both sides have sent what the other lacked; fails if the session ends first.
  Future<void> get live => _live.future;

  /// Completes when the session has ended.
  Future<void> get closed => session.done;

  /// Client side: the server said this device isn't approved yet; the session waits, and syncs
  /// as soon as a parent approves it.
  bool get awaitingApproval => _awaitingApproval && !_syncing;

  /// Why the session ended, when known.
  String? get closeReason => _closeReason ?? session.error?.message;

  /// Ends the session.
  Future<void> close() => session.close();

  // ------------------------------------------------------------------ lifecycle

  void _start() {
    _subscription = session.messages.listen(
      (message) => unawaited(_inbox.run(() => _dispatch(message))),
      onError: (Object error) => _closeReason ??= error is SessionException ? error.message : 'session error',
    );
    if (isClient) {
      final join = _join;
      if (join == null) {
        _trusted = _serverTrusted();
        if (!_trusted) {
          if (_serverRemoved()) {
            // A server this family removed hears so, with the signed record that says it, so it
            // can stop and tell its owner instead of waiting for devices that never sync again.
            unawaited(_tellRemoved());
          } else if (_den.device(deviceId) == null && session.peerFamily == _den.familyId && _isApproved()) {
            // A device of this family this one hasn't heard of yet: the hub that replaced the old
            // one, say, approved on a parent's phone since this one last synced. It may show its
            // record (`vouch`); nothing it sends counts until that holds up.
            _askToVouch();
          } else {
            unawaited(_violation('unknown-peer'));
          }
          return;
        }
        if (_isApproved()) _beginSync();
      } else {
        // A QR joiner pinned the inviting device's key in the handshake. A spoken-code joiner
        // pinned nothing: whatever answered is trusted only once it proves it knows the code
        // (`pair_ok`), so a stranger on the network can't feed it changes or a finished join.
        _trusted = join._code == null && session.pinned;
      }
    } else if (session.peerFamily != null && _peerApproved()) {
      _beginSync();
    } else if (session.peerFamily != null && _node._refused(deviceId)) {
      // A device turned away (or removed) hears so at once: one still waiting for approval
      // stops asking instead of being timed out over and over.
      unawaited(_reject('declined'));
    } else {
      // Strangers get a short while to prove an invite or code; once they have, they may wait
      // for a parent's approval for [SyncNode.pairingTimeout].
      _pairingTimer = Timer(_node.unpairedTimeout, () => unawaited(_violation('pairing-timeout')));
      if (session.peerFamily != null) unawaited(_send({'t': 'unapproved'}).catchError((Object _) {}));
    }
  }

  void _onClosed() {
    _pairingTimer?.cancel();
    // Let messages that arrived before the close (a refusal, the last changes) be handled first.
    unawaited(_inbox.run(() async {}).whenComplete(() {
      unawaited(_subscription?.cancel());
      _setPhase(PeerPhase.closed);
      if (!_live.isCompleted) _live.completeError(StateError('session closed: ${closeReason ?? 'disconnected'}'));
      _join?._fail(JoinStage.failed, closeReason ?? 'closed');
      unawaited(_phases.close());
    }));
  }

  void _setPhase(PeerPhase phase) {
    if (_phase == phase || _phase == PeerPhase.closed) return;
    _phase = phase;
    if (!_phases.isClosed) _phases.add(phase);
  }

  bool get _syncing => _phase == PeerPhase.syncing || _phase == PeerPhase.live;

  bool _isApproved() {
    try {
      return _den.isApproved;
    } on Object {
      return false;
    }
  }

  /// Server side: the client is an approved, unrevoked device of this family with this key.
  bool _peerApproved() {
    final d = _den.device(deviceId);
    return d != null && d.approved && !d.revoked && d.pubkey == pubkey;
  }

  /// Client side: the server is a device this family removed, with the key it had.
  bool _serverRemoved() {
    final d = _den.device(deviceId);
    return d != null && d.revoked && d.pubkey == pubkey;
  }

  void _askToVouch() {
    _vouching = true;
    _pairingTimer = Timer(_node.unpairedTimeout, () => unawaited(_violation('unknown-peer')));
    unawaited(_send({'t': 'vouch'}).catchError((Object _) {}));
  }

  /// Server side: a family device that doesn't know this one yet asks who it is. The answer is
  /// this device's own record: its request, the approval a parent signed, and what changed since.
  Future<void> _onVouch() async {
    if (isClient || !_den.hasFamily) return;
    await _send({
      't': 'vouched',
      'list': [
        for (final c in _den.changesSince(const {}, spaces: const {Space.family}))
          if (c.type == RecordType.device && c.rid == _den.deviceId) c.toJson(),
      ],
    });
  }

  /// Client side: keeps the server's record only when it holds up (its request signed with the
  /// key it proved in the handshake, and an approval signed by a parent's device this one already
  /// trusts), then syncs as with any approved device. Anything less, and it's a stranger.
  Future<void> _onVouched(Map<String, Object?> m) async {
    _pairingTimer?.cancel();
    final record = _deviceRecord(m['list'], deviceId);
    if (await _vouches(record)) await _den.ingest(record);
    _vouching = false;
    _trusted = _serverTrusted();
    if (!_trusted) {
      await (_serverRemoved() ? _tellRemoved() : _violation('unknown-peer'));
      return;
    }
    _beginSync();
    final waiting = [..._deferred];
    _deferred.clear();
    for (final d in waiting) {
      await _dispatch(d);
    }
  }

  Future<bool> _vouches(List<Change> record) async {
    var asked = false;
    var approved = false;
    for (final c in record) {
      if (!asked && c.device == deviceId && c.fields['pubkey'] == pubkey) {
        asked = await verifySignature(c.signedBytes, c.sig, pubkey);
      }
      final by = _den.device(c.device);
      final parent = by?.member == null ? null : _den.member(by!.member!);
      if (!approved && c.fields['approved'] == true && by != null && by.approved && !by.revoked && (parent?.isParent ?? false)) {
        approved = await verifySignature(c.signedBytes, c.sig, by.pubkey);
      }
    }
    return asked && approved;
  }

  /// The changes in [raw] to [device]'s own record in the family space; anything else is dropped.
  static List<Change> _deviceRecord(Object? raw, String device) {
    if (raw is! List) return const [];
    final out = <Change>[];
    for (final item in raw.take(256)) {
      final json = asJsonObject(item);
      if (json == null) continue;
      try {
        final c = Change.fromJson(json);
        if (c.type == RecordType.device && c.rid == device && c.space == Space.family) out.add(c);
      } on Object {
        // Not a change.
      }
    }
    return out;
  }

  /// Client side: tells a removed server so (`join_rejected`, reason `removed`), handing it the
  /// signed changes to its own device record, the revocation among them, and closes.
  Future<void> _tellRemoved() async {
    _closeReason ??= 'removed';
    final record = [
      for (final c in _den.changesSince(const {}, spaces: const {Space.family}))
        if (c.type == RecordType.device && c.rid == deviceId) c.toJson(),
    ];
    try {
      await _send({'t': 'join_rejected', 'reason': 'removed', 'list': record});
    } on Object {
      // Closing anyway.
    }
    await session.close();
  }

  /// Server side: a family device says this one was removed. Only changes to this device's own
  /// record are taken, and the engine keeps them only when their signatures and their author's
  /// permissions hold, so nobody can talk a hub out of the family who couldn't remove it.
  Future<void> _onRemoved(Map<String, Object?> m) async {
    final own = _deviceRecord(m['list'], _den.deviceId);
    if (own.isNotEmpty) await _den.ingest(own);
  }

  /// Client side: the server is known as approved, or the caller pinned its identity.
  bool _serverTrusted() {
    final d = _den.device(deviceId);
    if (d != null) return d.approved && !d.revoked && d.pubkey == pubkey;
    return session.pinned;
  }

  void _beginSync() {
    _pairingTimer?.cancel();
    _allowed = _node._spacesFor(deviceId);
    _setPhase(PeerPhase.syncing);
    unawaited(_inbox.run(_sendHave));
  }

  Future<void> _send(Map<String, Object?> message) async {
    if (session.isClosed) return;
    await session.send(message);
  }

  Future<void> _violation(String reason) async {
    _closeReason ??= reason;
    try {
      await _send({'t': 'error', 'code': reason});
    } on Object {
      // Closing anyway.
    }
    await session.close();
  }

  // ------------------------------------------------------------------ dispatch

  Future<void> _dispatch(Map<String, Object?> m) async {
    try {
      if (_vouching && !const {'vouched', 'error', 'join_rejected'}.contains(m['t'])) {
        // What the server sends before showing its record waits until it has.
        if (_deferred.length >= 64) throw _Violation('unknown-peer');
        _deferred.add(m);
        return;
      }
      switch (m['t']) {
        case 'have':
          await _onHave(m);
        case 'changes':
          await _onChanges(m, initial: true);
        case 'push':
          await _onChanges(m, initial: false);
        case 'keys':
          await _onKeys(m);
        case 'probe':
          await _onProbe(m);
        case 'probe_ok':
          await _onProbeOk(m);
        case 'pair':
          await _onPair(m);
        case 'join':
          await _onJoin(m);
        case 'pair_ok':
          await _onPairOk(m);
        case 'pair_fail':
        case 'join_rejected':
          _closeReason ??= m['reason'] as String? ?? 'rejected';
          if (!isClient && m['reason'] == 'removed') await _onRemoved(m);
          _join?._fail(JoinStage.rejected, _closeReason!);
          await session.close();
        case 'vouch':
          await _onVouch();
        case 'vouched':
          if (isClient && _vouching) await _onVouched(m);
        case 'join_pending':
          if (isClient && _trusted) _join?._set(JoinStage.waitingForApproval);
        case 'unapproved':
          if (isClient && _trusted && !_syncing) _awaitingApproval = true;
        case 'approved':
          if (isClient && _trusted && !_syncing) {
            _join?._set(JoinStage.syncing);
            _allowed = _node._spacesFor(deviceId);
            _setPhase(PeerPhase.syncing);
          }
        case 'error':
          _closeReason ??= 'peer: ${m['code'] ?? 'error'}';
          await session.close();
        default:
          break;
      }
    } on _Violation catch (v) {
      await _violation(v.reason);
    } on Object {
      await _violation('bad-message');
    }
  }

  // ------------------------------------------------------------------ sync

  Future<void> _sendHave() async {
    if (session.isClosed) return;
    _sentHave = true;
    _node._scanLocal();
    final mine = _node._spacesFor(_den.deviceId);
    final theirs = _node._spacesFor(deviceId);
    final declared = mine.isNotEmpty && theirs.isNotEmpty ? mine.intersection(theirs) : _node._index.spaces.toSet();
    final keyed = <String, List<Object>>{
      for (final space in {...mine, ...declared})
        if (_node._keyIn(space) case final k?) space: [k.epoch, k.hash],
    };
    await _send({
      't': 'have',
      'vv': {for (final s in declared) s: _node._index.summary(s)},
      'keys': keyed,
    });
  }

  Future<void> _onHave(Map<String, Object?> m) async {
    if (isClient) {
      if (!_trusted) throw _Violation('unknown-peer');
      if (!_syncing) {
        _join?._set(JoinStage.syncing);
        _allowed = _node._spacesFor(deviceId);
        _setPhase(PeerPhase.syncing);
      }
    } else if (!_syncing) {
      throw _Violation('not-approved');
    }
    final vv = asJsonObject(m['vv']) ?? const {};
    final keys = m['keys'];
    if (keys is Map) {
      for (final e in keys.entries) {
        final space = e.key, value = e.value;
        if (space is! String) continue;
        if (value is int) {
          _notePeerKey(space, value);
        } else if (value is List && value.length == 2 && value[0] is int && value[1] is String) {
          _notePeerKey(space, value[0] as int, value[1] as String);
        }
      }
    } else if (keys is List) {
      for (final space in keys.whereType<String>()) {
        _notePeerKey(space, 0);
      }
    }
    final peerVv = <String, Map<String, List<int>>>{};
    for (final entry in vv.entries) {
      final authors = asJsonObject(entry.value);
      if (authors == null) throw _Violation('bad-have');
      final parsed = <String, List<int>>{};
      for (final a in authors.entries) {
        final triple = a.value;
        if (triple is! List || triple.length != 3 || triple.any((x) => x is! int)) throw _Violation('bad-have');
        parsed[a.key] = triple.cast<int>();
        _noteKnown(entry.key, a.key, triple[0] as int);
      }
      peerVv[entry.key] = parsed;
    }

    // Everything from here to _haveHandled is synchronous, so a local write lands either in
    // this answer or in a later push, never in neither.
    _node._scanLocal();
    _allowed = _node._spacesFor(deviceId);
    final outgoing = <Change>[];
    final probes = <String, Map<String, int>>{};
    for (final space in _allowed) {
      final authors = _node._index.space(space);
      if (authors.isEmpty) continue;
      final theirs = peerVv[space] ?? const {};
      final since = <String, int>{};
      var needed = false;
      for (final entry in authors.entries) {
        final mine = entry.value;
        final claim = theirs[entry.key];
        var from = 0;
        if (claim != null && claim[0] >= mine.max) {
          // The peer is level or ahead: nothing to send unless it has holes below our max,
          // which a probe of that range finds.
          from = mine.max;
          if (claim[0] > mine.max) {
            (probes[space] ??= {})[entry.key] = mine.max;
          } else {
            final summary = mine.summaryUpTo(mine.max);
            if (summary.count != claim[1] || summary.digest != claim[2]) from = 0;
          }
        } else if (claim != null) {
          final summary = mine.summaryUpTo(claim[0]);
          if (summary.count == claim[1] && summary.digest == claim[2]) from = claim[0];
        }
        since[entry.key] = from;
        if (from < mine.max) needed = true;
        _noteKnown(space, entry.key, mine.max);
      }
      if (needed) outgoing.addAll(_den.changesSince(since, spaces: {space}));
    }
    _haveHandled = true;
    outgoing.sort((a, b) => a.hlc.compareTo(b.hlc));
    // Changes, then keys, then the end marker: a revocation always precedes the keys it rotated,
    // and a joiner holds its keys by the time it counts itself caught up.
    await _sendBatches('changes', outgoing);
    await _sendMissingKeys();
    await _send({'t': 'changes', 'list': const <Object?>[], 'done': true});
    if (probes.isNotEmpty) await _send({'t': 'probe', 'vv': probes});
    _initialSent = true;
    if (!_sentHave) await _sendHave();
    _checkLive();
  }

  /// Answers a probe: our summary of each author's counters up to the asked bound, for spaces
  /// the asker may hold.
  Future<void> _onProbe(Map<String, Object?> m) async {
    if (!_syncing || (isClient && !_trusted)) throw _Violation('not-approved');
    final allowed = _node._spacesFor(deviceId);
    final answer = <String, Map<String, List<int>>>{};
    for (final entry in (asJsonObject(m['vv']) ?? const {}).entries) {
      if (!allowed.contains(entry.key)) continue;
      final authors = _node._index.space(entry.key);
      for (final a in (asJsonObject(entry.value) ?? const {}).entries) {
        final bound = a.value;
        if (bound is! int) throw _Violation('bad-probe');
        final summary = authors[a.key]?.summaryUpTo(bound) ?? (count: 0, digest: 0);
        (answer[entry.key] ??= {})[a.key] = [bound, summary.count, summary.digest];
      }
    }
    await _send({'t': 'probe_ok', 'vv': answer});
  }

  /// Sends whole author histories where the peer's probed range differs from ours.
  Future<void> _onProbeOk(Map<String, Object?> m) async {
    if (!_syncing || (isClient && !_trusted)) throw _Violation('not-approved');
    final out = <Change>[];
    for (final entry in (asJsonObject(m['vv']) ?? const {}).entries) {
      final space = entry.key;
      if (!_allowed.contains(space)) continue;
      final authors = _node._index.space(space);
      final repair = <String>{};
      for (final a in (asJsonObject(entry.value) ?? const {}).entries) {
        final triple = a.value;
        if (triple is! List || triple.length != 3 || triple.any((x) => x is! int)) throw _Violation('bad-probe');
        final mine = authors[a.key];
        if (mine == null) continue;
        final summary = mine.summaryUpTo(triple[0] as int);
        if (summary.count != triple[1] || summary.digest != triple[2]) repair.add(a.key);
      }
      if (repair.isEmpty) continue;
      final since = {for (final e in authors.entries) e.key: repair.contains(e.key) ? 0 : e.value.max};
      out.addAll(_den.changesSince(since, spaces: {space}));
    }
    if (out.isNotEmpty) {
      out.sort((a, b) => a.hlc.compareTo(b.hlc));
      await _sendBatches('push', out);
    }
  }

  Future<void> _onChanges(Map<String, Object?> m, {required bool initial}) async {
    if (!_syncing || (isClient && !_trusted)) throw _Violation('not-approved');
    final raw = m['list'];
    if (raw is! List) throw _Violation('bad-changes');
    final list = <Change>[];
    for (final item in raw) {
      final json = asJsonObject(item);
      if (json == null) throw _Violation('bad-changes');
      list.add(Change.fromJson(json));
    }
    final peerKnown = _den.device(deviceId) != null;
    final peerSpaces = _node._spacesFor(deviceId);
    final accepted = [
      for (final c in list)
        if (!peerKnown || peerSpaces.contains(c.space)) c,
    ];
    for (final c in list) {
      _noteKnown(c.space, c.device, c.counter);
    }
    if (accepted.isNotEmpty) await _node._ingestFrom(this, accepted);
    if (initial && m['done'] == true) {
      _initialReceived = true;
      _checkLive();
    }
  }

  /// Offers a space key to the engine, which keeps it when its maker's statement verifies: a
  /// newer epoch becomes current, another key for an epoch already held becomes a candidate for
  /// it (every replica picks the same one), an older epoch is kept for reading old mailboxes.
  /// Whatever changed the key in use is passed on to other peers. Keys for spaces the sender
  /// may not hold, and keys without a valid statement, are ignored.
  Future<void> _onKeys(Map<String, Object?> m) async {
    if (!_syncing || (isClient && !_trusted)) throw _Violation('not-approved');
    final grant = SpaceKeyGrant.fromJson(m);
    if (grant == null) throw _Violation('bad-keys');
    final key = grant.spaceKey;
    _notePeerKey(key.space, key.epoch, key.hash);
    if (_den.device(deviceId) != null && !_node._spacesFor(deviceId).contains(key.space)) return;
    if (await _den.addSpaceKey(key) == SpaceKeyOutcome.stored) _node._scheduleChangeScan();
  }

  void _notePeerKey(String space, int epoch, [String? hash]) {
    final known = _peerEpochs[space] ?? -1;
    if (epoch > known) {
      _peerEpochs[space] = epoch;
      _peerHashes[space] = {?hash};
    } else if (epoch == known && hash != null) {
      _peerHashes.putIfAbsent(space, () => {}).add(hash);
    }
  }

  /// Sends the key in use for each space the peer may hold (by this replica's view, right now)
  /// unless the peer has said it holds a newer epoch, or that very key.
  Future<void> _sendMissingKeys() async {
    if (!_syncing || session.isClosed || _node._keyPushHolds > 0) return;
    for (final space in _node._spacesFor(deviceId)) {
      final key = await _den.spaceKeyToShare(space);
      if (key == null) continue;
      final peerEpoch = _peerEpochs[space] ?? -1;
      if (peerEpoch > key.epoch || (peerEpoch == key.epoch && (_peerHashes[space]?.contains(key.hash) ?? false))) {
        continue;
      }
      _notePeerKey(space, key.epoch, key.hash);
      await _send(SpaceKeyGrant.of(key).toJson());
    }
  }

  void _checkLive() {
    if (_initialSent && _initialReceived && !_live.isCompleted) {
      _setPhase(PeerPhase.live);
      _live.complete();
      _join?._set(JoinStage.done);
    }
  }

  void _noteKnown(String space, String author, int counter) {
    final authors = _known[space] ??= {};
    if (counter > (authors[author] ?? 0)) authors[author] = counter;
  }

  /// Sends changes that just became new to this replica, if this peer may hold them.
  void _forward(List<Change> changes) {
    if (!_syncing || session.isClosed) return;
    final spaces = _node._spacesFor(deviceId);
    final out = [
      for (final c in changes)
        if (spaces.contains(c.space)) c,
    ];
    for (final c in out) {
      _noteKnown(c.space, c.device, c.counter);
    }
    if (out.isNotEmpty) unawaited(_sendBatches('push', out).catchError((Object _) {}));
  }

  Future<void> _onDenChanged({required bool mySpacesChanged}) async {
    if (session.isClosed) return;
    if (_phase == PeerPhase.pairing) {
      if (!isClient) await _checkApproval();
      return;
    }
    final d = _den.device(deviceId);
    if (d != null && (d.revoked || !d.approved || d.pubkey != pubkey)) {
      // A hub removed while this device is connected to it hears why on the way out.
      await (isClient && _serverRemoved() ? _tellRemoved() : _violation('revoked'));
      return;
    }
    final allowed = _node._spacesFor(deviceId);
    _allowed = allowed;
    // Until the peer's `have` is answered, that answer will carry everything. Keys follow from
    // the node once every peer has its changes.
    if (!_haveHandled) return;
    final out = <Change>[];
    for (final space in allowed) {
      final authors = _node._index.space(space);
      final known = _known[space] ?? const {};
      final since = <String, int>{};
      var needed = false;
      for (final entry in authors.entries) {
        final k = known[entry.key] ?? 0;
        since[entry.key] = k;
        if (entry.value.max > k) needed = true;
      }
      if (!needed) continue;
      for (final c in _den.changesSince(since, spaces: {space})) {
        out.add(c);
        _noteKnown(space, c.device, c.counter);
      }
    }
    if (out.isNotEmpty) {
      out.sort((a, b) => a.hlc.compareTo(b.hlc));
      await _sendBatches('push', out);
    }
    if (mySpacesChanged) await _sendHave();
  }

  Future<void> _sendBatches(String type, List<Change> changes, {bool finalFlag = false}) async {
    var batch = <Map<String, Object?>>[];
    var bytes = 0;
    Future<void> flush({required bool last}) async {
      await _send({
        't': type,
        'list': batch,
        if (finalFlag) 'done': last,
      });
      batch = [];
      bytes = 0;
    }

    for (final c in changes) {
      final json = c.toJson();
      final size = jsonEncode(json).length;
      if (batch.isNotEmpty && (bytes + size > _batchBytes || batch.length >= _batchChanges)) {
        await flush(last: false);
      }
      batch.add(json);
      bytes += size;
    }
    if (batch.isNotEmpty || finalFlag) await flush(last: true);
  }

  // ------------------------------------------------------------------ pairing, inviting side

  Future<void> _onPair(Map<String, Object?> m) async {
    if (isClient) throw _Violation('unexpected-pair');
    if (_phase != PeerPhase.pairing || _pairedVia != null) return;
    final kind = m['kind'];
    final proof = m['proof'];
    if (proof is! String) throw _Violation('bad-pair');
    if (_node._refused(deviceId)) {
      _closeReason = 'declined';
      await _send({'t': 'pair_fail', 'reason': 'declined'});
      await session.close();
      return;
    }
    String? hostProof;
    var ok = false;
    if (kind == 'qr') {
      ok = session.peerFamily == _den.familyId && await _node.invites.redeem(pubkey, proof) != null;
    } else if (kind == 'code') {
      final code = await _node.codes.redeemProof(proof, session.transcriptHash, pubkey);
      if (code != null) {
        ok = true;
        hostProof = await hostCodeProof(code.text, session.transcriptHash, _den.keys.pubkey);
      }
    }
    if (!ok) {
      _closeReason = 'bad-proof';
      await _send({'t': 'pair_fail', 'reason': 'bad-proof'});
      await session.close();
      return;
    }
    _pairedVia = kind as String;
    _pairingTimer?.cancel();
    _pairingTimer = Timer(_node.pairingTimeout, () => unawaited(_violation('pairing-timeout')));
    final family = _den.family;
    final founderDevice = family?.founderDevice;
    final founder = founderDevice == null
        ? null
        : founderDevice == _den.deviceId
            ? _den.keys.pubkey
            : _den.device(founderDevice)?.pubkey;
    await _send({
      't': 'pair_ok',
      'family': _den.familyId,
      'founder': founder,
      'proof': ?hostProof,
    });
  }

  Future<void> _onJoin(Map<String, Object?> m) async {
    if (isClient) throw _Violation('unexpected-join');
    if (_phase != PeerPhase.pairing) return;
    // Every request, a device's first or one it made before, comes with a fresh proof of an
    // invite or code: a request already in the log proves nothing about who is asking now.
    if (_pairedVia == null) return _reject('not-paired');
    if (_node._refused(deviceId)) return _reject('declined');
    final raw = m['changes'];
    if (raw is! List || raw.isEmpty || raw.length > 16) return _reject('bad-request');
    final changes = <Change>[];
    for (final item in raw) {
      final json = asJsonObject(item);
      if (json == null) return _reject('bad-request');
      final Change c;
      try {
        c = Change.fromJson(json);
      } on Object {
        return _reject('bad-request');
      }
      if (!await _isOwnJoinRecord(c)) return _reject('bad-request');
      changes.add(c);
    }
    final result = await _node._ingestFrom(this, changes);
    if (result != null && changes.any((c) => result.invalid.containsKey(c.id))) return _reject('invalid');
    final device = _den.device(deviceId);
    if (device == null || device.revoked || device.pubkey != pubkey) return _reject('invalid');
    if (device.approved) {
      _beginApproved();
      return;
    }
    _node._addPending(PendingJoin._(
      deviceId: deviceId,
      name: device.name,
      kind: device.kind,
      requestedMode: device.mode,
      requestedMember: device.member,
      matchingWords: session.matchingWords,
      via: _pairedVia!,
      since: DateTime.now().toUtc(),
      peer: this,
    ));
    await _send({'t': 'join_pending'});
  }

  /// A change the joiner may send before approval: only its own device record, never setting
  /// approval or revocation. (den_core independently refuses self-approval.)
  Future<bool> _isOwnJoinRecord(Change c) async {
    if (c.device != deviceId || c.type != RecordType.device || c.rid != deviceId || c.space != Space.family) {
      return false;
    }
    final f = c.fields;
    if (f.containsKey('approved') && f['approved'] != false) return false;
    if (f['approvedBy'] != null) return false;
    if (f.containsKey('revoked') && f['revoked'] != false) return false;
    if (f.containsKey('pubkey') && f['pubkey'] != pubkey) return false;
    if (f['_deleted'] == true) return false;
    return verifySignature(c.signedBytes, c.sig, pubkey);
  }

  Future<void> _reject(String reason) async {
    _closeReason = reason;
    _node._removePending(this);
    await _send({'t': 'join_rejected', 'reason': reason});
    await session.close();
  }

  Future<void> _checkApproval() async {
    final d = _den.device(deviceId);
    if (d == null) return;
    if (d.revoked) {
      await _reject('revoked');
      return;
    }
    if (d.approved && d.pubkey == pubkey) _beginApproved();
  }

  void _beginApproved() {
    _node._removePending(this);
    unawaited(_send({'t': 'approved'}).catchError((Object _) {}));
    _beginSync();
  }

  // ------------------------------------------------------------------ pairing, joining side

  Future<void> _onPairOk(Map<String, Object?> m) async {
    final attempt = _join;
    if (!isClient || attempt == null) throw _Violation('unexpected-pair-ok');
    final family = m['family'];
    final founder = m['founder'];
    if (family is! String || founder is! String) throw _Violation('bad-pair-ok');
    final invite = attempt._invite;
    if (invite != null) {
      if (family != invite.familyId || founder != invite.founderPubkey) throw _Violation('wrong-family');
      return;
    }
    final code = attempt._code!;
    final proof = m['proof'];
    final expected = await hostCodeProof(code, session.transcriptHash, pubkey);
    if (proof is! String || !constantTimeEquals(utf8.encode(proof), utf8.encode(expected))) {
      _closeReason = 'host-proof';
      attempt._fail(JoinStage.rejected, 'host-proof');
      await session.close();
      return;
    }
    _trusted = true;
    final request = attempt._request!;
    if (!_den.hasFamily) {
      await _den.requestJoin(
        familyId: family,
        founderPubkey: founder,
        deviceName: request.deviceName,
        kind: request.kind,
        mode: request.mode,
        memberId: request.memberId,
      );
    } else if (_den.familyId != family) {
      throw _Violation('wrong-family');
    }
    await _send({'t': 'join', 'changes': _node._ownJoinChanges()});
  }
}

class _Violation implements Exception {
  _Violation(this.reason);
  final String reason;
}
