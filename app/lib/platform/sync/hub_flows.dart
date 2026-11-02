import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' as net;

import 'den_network.dart';
import 'hub_client.dart';
import 'pairing.dart';

/// Adding a fresh hub from a parent's phone, following den_hub's setup flow: make an invite,
/// `POST /api/v1/hub/setup {code, invite, direct: true}`, open `/api/v1/hub/setup/ws` and serve
/// this side of the pairing session there, then approve the hub's join as mode hub and save its
/// address as the place to sync.
class NetHubSetup extends HubSetupSession {
  NetHubSetup({
    required this.network,
    required this.client,
    required this.hub,
    required this.code,
    this.waitFor = const Duration(minutes: 2),
    this.autoApprove = false,
    this.expectDevice,
  });

  final DenNetwork network;
  final HubClient client;
  @override
  final HubInfo hub;
  final String code;

  /// Approves the hub without a tap once it reports the same words this device shows: for a
  /// browser the hub itself served, where nothing sits between the two to compare against.
  final bool autoApprove;

  /// The hub's device id from its setup link: only that hub is taken in, and at once, since the
  /// session proved it holds the key the id is the hash of. No words to compare.
  final String? expectDevice;

  /// How long to wait for the hub to ask to join, and then to catch up after approval.
  final Duration waitFor;

  HubSetupStage _stage = HubSetupStage.sending;
  String? _error;
  net.PendingJoin? _join;
  List<String> _hubWords = const [];
  StreamSubscription<List<net.PendingJoin>>? _pendingSub;
  bool _closed = false;

  @override
  HubSetupStage get stage => _stage;

  @override
  String? get error => _error;

  @override
  List<String> get words => _join?.matchingWords ?? const [];

  @override
  List<String> get hubWords => _hubWords;

  net.SyncNode get _node => network.activeNode;

  void _set(HubSetupStage stage, {String? error}) {
    if (_closed) return;
    _stage = stage;
    _error = error;
    notifyListeners();
  }

  /// Runs the flow up to the point a parent approves.
  Future<void> run() async {
    final expected = expectDevice;
    if (expected != null && hub.device != expected) {
      _set(
        HubSetupStage.failed,
        error: "The hub at ${hub.address} isn't the one that printed this link. Check the link, or type the setup code from the hub's log.",
      );
      return;
    }
    try {
      final invite = await _node.createInvite(validFor: const Duration(minutes: 15));
      await client.sendSetup(hub.base, code: code, invite: invite.toUrl(), direct: true);
      _set(HubSetupStage.waiting);
      final joined = Completer<net.PendingJoin>();
      void check(List<net.PendingJoin> joins) {
        for (final j in joins) {
          if (j.deviceId == hub.device && !joined.isCompleted) joined.complete(j);
        }
      }

      _pendingSub = _node.pendingJoinsChanges.listen(check);
      final socket = await net.connectWebSocket(
        hub.base.replace(scheme: hub.base.scheme == 'https' ? 'wss' : 'ws', path: '/api/v1/hub/setup/ws'),
      );
      unawaited(_node.serve(socket));
      check(_node.pendingJoins);
      _join = await joined.future.timeout(waitFor);
      await _pendingSub?.cancel();
      if (expected != null && _join!.deviceId == expected) {
        // The link named this hub's key: nothing to compare.
        _set(HubSetupStage.confirm);
        await approve();
        return;
      }
      _hubWords = await _wordsFromHub();
      _set(HubSetupStage.confirm);
      if (autoApprove && wordsMatch == true) {
        await approve();
      } else if (autoApprove && wordsMatch == false) {
        await _node.decline(_join!);
        _set(
          HubSetupStage.failed,
          error: "${hub.name} showed different words than this page, so it wasn't added. Reload Den and try again.",
        );
      }
    } on HubException catch (e) {
      final tries = e.triesLeft;
      _set(
        HubSetupStage.failed,
        error: e.code == 'permission_denied' && tries != null && tries > 0
            ? "That setup code isn't right. Check it in the hub's log: $tries more ${tries == 1 ? 'try' : 'tries'}, then the hub makes you wait a minute."
            : e.message,
      );
    } on TimeoutException {
      _set(
        HubSetupStage.failed,
        error: "${hub.name} didn't ask to join in time. Check that it's still on, then try again with its new setup code.",
      );
    } on Object {
      _set(
        HubSetupStage.failed,
        error: "Couldn't finish connecting to ${hub.name}. Check that this phone and the hub are on the same network, then try again.",
      );
    }
  }

  /// What the hub's status says the words are. The hub may answer a moment after its join
  /// request arrives, so ask a few times; an older hub or one that doesn't answer says nothing.
  Future<List<String>> _wordsFromHub() async {
    for (var i = 0; i < 6 && !_closed; i++) {
      try {
        final info = await client.status(hub.base);
        if (info.matchingWords.isNotEmpty) return info.matchingWords;
        if (info.paired || info.stage == 'waiting_for_code') return const [];
      } on HubException {
        return const [];
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return const [];
  }

  @override
  Future<void> approve() async {
    final join = _join;
    if (join == null || _stage != HubSetupStage.confirm || wordsMatch == false) return;
    _set(HubSetupStage.approving);
    try {
      await _node.approve(join, mode: DeviceMode.hub);
      final deadline = DateTime.now().add(waitFor);
      while (DateTime.now().isBefore(deadline)) {
        final info = await client.status(hub.base).catchError((Object _) => hub);
        if (info.paired) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await network.addHub(hub.base.toString());
      _set(HubSetupStage.done);
    } on PermissionDenied catch (e) {
      _set(HubSetupStage.failed, error: e.message);
    } on InvalidInput catch (e) {
      _set(HubSetupStage.failed, error: e.message);
    } on Object {
      _set(HubSetupStage.failed, error: "Approved ${hub.name}, but couldn't save its address. Add it in Settings, This device.");
    }
  }

  @override
  Future<void> cancel() async {
    await _pendingSub?.cancel();
    final join = _join;
    if (join != null && _stage == HubSetupStage.confirm) {
      await _node.decline(join);
      try {
        await network.den.revokeDevice(join.deviceId);
      } on Object {
        // The request may not have reached this replica; declining the session is enough.
      }
    }
    _closed = true;
  }

  @override
  void dispose() {
    unawaited(_pendingSub?.cancel());
    _closed = true;
    super.dispose();
  }
}

/// A browser the hub served asking to be linked: shows the hub's link code, polls for the
/// invite a parent's phone leaves, then joins over the hub's `/ws`.
class NetBrowserLink extends BrowserLinkSession {
  NetBrowserLink({
    required this.client,
    required this.hub,
    required this.slot,
    required this.deviceName,
    required this.join,
    this.every = const Duration(seconds: 2),
  });

  final HubClient client;
  @override
  final Uri hub;
  final LinkSlot slot;
  final String Function() deviceName;

  /// Sends the join with the invite over the hub's sync socket.
  final Future<JoinTicket> Function(net.Invite invite, Uri sync, String deviceName) join;
  final Duration every;

  LinkStage _stage = LinkStage.waiting;
  String? _error;
  JoinTicket? _ticket;
  Timer? _timer;
  bool _busy = false;

  @override
  String get uri => slot.uri;

  @override
  int get expires => slot.expires;

  @override
  LinkStage get stage => _stage;

  @override
  String? get error => _error;

  @override
  JoinTicket? get ticket => _ticket;

  void start() {
    _timer = Timer.periodic(every, (_) => _poll());
  }

  void _set(LinkStage stage, {String? error}) {
    _stage = stage;
    _error = error;
    notifyListeners();
  }

  Future<void> _poll() async {
    if (_busy || _stage != LinkStage.waiting) return;
    if (DateTime.now().millisecondsSinceEpoch >= slot.expires) {
      _timer?.cancel();
      _set(LinkStage.expired);
      return;
    }
    _busy = true;
    try {
      final inviteUrl = await client.pollLink(hub, slot);
      if (inviteUrl == null) return;
      _timer?.cancel();
      _set(LinkStage.joining);
      final invite = await net.Invite.parse(inviteUrl);
      _ticket = await join(invite, HubClient.syncUri(hub), deviceName());
      _set(LinkStage.joined);
    } on HubException catch (e) {
      _timer?.cancel();
      _set(e.code == 'not_found' ? LinkStage.expired : LinkStage.failed, error: e.message);
    } on PairingException catch (e) {
      _set(LinkStage.failed, error: e.message);
    } on Object {
      _timer?.cancel();
      _set(LinkStage.failed, error: "Couldn't join through the hub. Reload this page to get a new code.");
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> cancel() async => _timer?.cancel();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
