import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' as net;
import 'package:flutter/foundation.dart';

import 'den_network.dart';
import 'hub_client.dart';
import 'hub_flows.dart';
import 'local_stub.dart' if (dart.library.io) 'local_io.dart' as local;
import 'pairing.dart';

/// [PairingService] on den_net: QR invites and spoken codes over the hub, the relay's
/// rendezvous, or (with neither) a direct connection on the same Wi-Fi.
class NetPairing extends PairingService {
  NetPairing(this.network, {HubClient? client, this.servedBy}) : _client = client ?? HubClient() {
    network.addListener(_watchTurnedAway);
  }

  static const _turnedAway = JoinStatus(
    JoinState.declined,
    message: 'A parent turned this device away. Ask them for a new invite, then start over.',
  );

  final DenNetwork network;

  /// The hub that served this browser; defaults to the page's own origin on the web.
  final Uri? servedBy;
  final HubClient _client;
  final StreamController<JoinStatus> _status = StreamController.broadcast();

  /// The in-process hub's node while this device is the hub, so joiners reaching it find the
  /// invites made here.
  net.SyncNode get _node => network.activeNode;

  bool _toldTurnedAway = false;

  /// A device waiting for approval learns it was turned away from its connection to the family.
  void _watchTurnedAway() {
    if (!network.turnedAway || _toldTurnedAway) return;
    _toldTurnedAway = true;
    _status.add(_turnedAway);
  }

  @override
  Stream<JoinStatus> get joinStatus async* {
    if (network.turnedAway) yield _turnedAway;
    yield* _status.stream;
  }

  @override
  Future<JoinTicket> joinWithQr(String uri, {required String deviceName, required DeviceKind kind}) async {
    final net.Invite invite;
    try {
      invite = await net.Invite.parse(uri);
    } on Object {
      throw const PairingException("That isn't a Den invite, or it has expired. Ask for a new code.");
    }
    final channel = await _open(() => net.openInviteChannel(invite));
    final attempt = await _node.joinWithInvite(channel, invite, deviceName: deviceName, kind: kind);
    await network.rememberJoin(invite.inviterDevice, invite.hubs.firstOrNull);
    _follow(attempt, hubs: invite.hubs);
    return JoinTicket(familyId: invite.familyId, words: attempt.matchingWords);
  }

  @override
  Future<JoinTicket> joinWithCode(
    String words, {
    String? hubUrl,
    required String deviceName,
    required DeviceKind kind,
  }) async {
    final code = net.normalizeCode(words);
    if (code == null) {
      throw const PairingException("Those aren't four words from a Den code. Check them against the other screen.");
    }
    final hub = hubUrl == null ? null : DenNetwork.syncUriFor(hubUrl);
    final relay = network.relay;
    final channel = await _open(() async {
      if (hub != null) return net.connectWebSocket(hub);
      if (relay != null) return net.rendezvous(relay, await net.codeRendezvousSlot(code), host: false);
      throw const PairingException("Enter the hub's address to join with a code, or scan the QR code instead.");
    });
    final attempt = await _node.joinWithCode(channel, code, deviceName: deviceName, kind: kind);
    if (hub != null) await network.rememberJoin(attempt.peer.deviceId, hub);
    _follow(attempt, hubs: [?hub]);
    return JoinTicket(familyId: network.den.familyId ?? '', words: attempt.matchingWords);
  }

  @override
  Future<String> createInviteQr() async {
    final hubs = await _reachableHubs();
    final relay = network.relay;
    final invite = await _node.createInvite(hubs: hubs, relay: relay);
    if (hubs.isEmpty && relay != null) {
      unawaited(_node.hostRendezvous(relay, await invite.rendezvousSlot()).catchError((Object _) {}));
    }
    return invite.toUrl();
  }

  @override
  Future<SpokenCode> createSpokenCode() async {
    final relay = network.relay;
    final code = _node.createSpokenCode();
    if (relay != null) {
      unawaited(_node.hostRendezvous(relay, await net.codeRendezvousSlot(code.text)).catchError((Object _) {}));
    } else if (network.isHub && network.localHub.node != null) {
      // Joiners type this device's address as the hub address; its hub accepts the code.
    } else if (await local.serveTemporarily(_node) == null) {
      throw const PairingException('Spoken codes need the hub, a relay, or both devices on the same Wi-Fi.');
    }
    return SpokenCode(words: code.words, expires: code.expires.toUtc().millisecondsSinceEpoch);
  }

  @override
  Stream<List<PendingJoin>> get pendingJoins async* {
    yield _convert(_node.pendingJoins);
    yield* _node.pendingJoinsChanges.map(_convert);
  }

  // ------------------------------------------------------------------ hubs

  @override
  Future<List<FoundHub>> findHubs() => local.findHubsNearby();

  @override
  Future<HubInfo> hubStatus(String address) async {
    final base = HubClient.baseFor(address);
    if (base == null) throw const PairingException("That isn't a hub address. Type something like 192.168.1.20.");
    try {
      return await _client.status(base);
    } on HubException catch (e) {
      throw PairingException(e.message);
    }
  }

  @override
  HubSetupSession setUpHub(HubInfo hub, String code) =>
      NetHubSetup(network: network, client: _client, hub: hub, code: code)..run();

  @override
  Future<void> useHub(HubInfo hub) => network.addHub(hub.base.toString());

  // ------------------------------------------------------------------ browsers

  @override
  Future<BrowserLinkSession> linkThisBrowser({required String Function() deviceName}) async {
    final base = servedBy ?? (kIsWeb ? Uri.base : null);
    if (base == null || base.host.isEmpty) {
      throw const PairingException('Only a browser opened from the hub can link this way. Scan a code instead.');
    }
    final hub = Uri(scheme: base.scheme, host: base.host, port: base.port);
    final LinkSlot slot;
    try {
      slot = await _client.openLink(hub);
    } on HubException catch (e) {
      throw PairingException(e.code == 'not_ready'
          ? "This hub isn't in a family yet. Add it from a parent's phone first: Family, Devices, Add a device."
          : e.message);
    }
    return NetBrowserLink(client: _client, hub: hub, slot: slot, deviceName: deviceName, join: _joinLinked)..start();
  }

  Future<JoinTicket> _joinLinked(net.Invite invite, Uri sync, String deviceName) async {
    final channel = await _open(() => net.connectWebSocket(sync));
    final attempt = await _node.joinWithInvite(channel, invite, deviceName: deviceName, kind: DeviceKind.browser);
    await network.rememberJoin(invite.inviterDevice, sync);
    _follow(attempt, hubs: [sync]);
    return JoinTicket(familyId: invite.familyId, words: attempt.matchingWords);
  }

  @override
  Future<String> answerBrowserLink(String code) async {
    final link = LinkCode.parse(code);
    if (link == null) {
      throw const PairingException(
        "That isn't a browser link code. On the computer, open the hub's address and choose Link this browser.",
      );
    }
    final den = network.den;
    if (!isFamilyHub(den, link.hubDevice)) {
      throw const PairingException(
        "That code comes from a hub that isn't in this family. Open the browser on your family's hub address.",
      );
    }
    final invite = _node.createHubInvite(link.hubDevice, hubs: [HubClient.syncUri(link.base)]);
    final grant = await net.InviteGrant.sign(invite, keys: den.keys, context: 'link:${link.slot}');
    try {
      await _client.grantLink(link.base, link.slot, grant.toJson());
    } on HubException catch (e) {
      throw PairingException(e.message);
    }
    if (!network.hubs.contains(DenNetwork.syncUriFor(link.base.toString()))) {
      unawaited(network.addHub(link.base.toString()));
    }
    return den.device(link.hubDevice)?.name ?? 'the hub';
  }

  /// The hub that served this page: [servedBy], or the page's own origin on the web.
  Uri? get _servedBase {
    final base = servedBy ?? (kIsWeb ? Uri.base : null);
    if (base == null || base.host.isEmpty) return null;
    return Uri(scheme: base.scheme, host: base.host, port: base.port);
  }

  @override
  Future<HubInfo?> servingHub() async {
    final base = _servedBase;
    if (base == null) return null;
    try {
      return await _client.status(base);
    } on HubException {
      return null;
    }
  }

  @override
  HubSetupSession adoptServingHub(HubInfo hub, String code) =>
      NetHubSetup(network: network, client: _client, hub: hub, code: code, autoApprove: true)..run();

  /// How long an invite sent as a message works.
  static const inviteLife = Duration(days: 3);

  @override
  Future<InviteMessage> createInvite({String? memberId}) async {
    final den = network.den;
    final hub = network.hubDevice;
    if (network.isHub) {
      throw const PairingException('This device is the hub. Invite from your phone, or show the code below to the new device.');
    }
    if (hub == null) {
      throw const PairingException("Invites by message go through the family's hub. Add the hub first: Family, Devices, Add a device.");
    }
    final bases = await network.hubBases();
    if (bases.isEmpty) throw const PairingException("Den doesn't know the hub's address yet. Open Den at home once, then try again.");
    HubException? last;
    for (final base in bases) {
      final net.Invite invite;
      try {
        invite = _node.createHubInvite(hub.id, hubs: [HubClient.syncUri(base)], validFor: inviteLife);
      } on StateError {
        throw const PairingException("This device doesn't know the family's hub well enough yet. Wait a moment, then try again.");
      }
      final grant = await net.InviteGrant.sign(
        invite,
        keys: den.keys,
        context: memberId == null ? 'invite' : 'invite:$memberId',
      );
      try {
        final made = await _client.createInvite(base, grant.toJson());
        return InviteMessage(
          words: made.words,
          link: made.link,
          expires: made.expires,
          familyName: den.family?.name ?? 'the family',
          qr: invite.toUrl(),
          forName: memberId == null ? null : den.member(memberId)?.name,
        );
      } on HubException catch (e) {
        if (e.code != null) {
          throw PairingException(e.code == 'not_found'
              ? "The family's hub can't make invites yet. Update it, then try again."
              : e.message);
        }
        last = e;
      }
    }
    throw PairingException(last?.message ?? "Couldn't reach the family's hub. Try again.");
  }

  @override
  Future<JoinTicket> joinWithInvite(
    String words, {
    String? hubUrl,
    required String Function(String? forName) deviceName,
    required DeviceKind kind,
  }) async {
    final code = net.normalizeCode(words);
    if (code == null) {
      throw const PairingException("Those aren't the four words from an invite. Check them against the message.");
    }
    final base = hubUrl == null || hubUrl.trim().isEmpty ? _servedBase : HubClient.baseFor(hubUrl);
    if (base == null) throw const PairingException("Type the hub's address too. It's the start of the invite's link.");
    final RedeemedInvite redeemed;
    try {
      redeemed = await _client.redeemInvite(base, code);
    } on HubException catch (e) {
      if (e.code == 'not_found') {
        throw const PairingException(
          "That code isn't right, or the invite has expired. Ask for a new invite.",
          reason: PairingException.unknownCode,
        );
      }
      throw PairingException(e.code == 'not_ready' ? "This hub isn't in a family yet. Start your family first." : e.message);
    }
    final net.Invite invite;
    try {
      invite = await net.Invite.parse(redeemed.invite);
    } on FormatException {
      throw const PairingException('This invite has expired. Ask for a new one.');
    }
    final sync = HubClient.syncUri(base);
    final channel = await _open(() => net.connectWebSocket(sync));
    final attempt = await _node.joinWithInvite(
      channel,
      invite,
      deviceName: deviceName(redeemed.memberName),
      kind: kind,
      memberId: redeemed.member,
    );
    await network.rememberJoin(invite.inviterDevice, sync);
    _follow(attempt, hubs: [sync]);
    return JoinTicket(familyId: invite.familyId, familyName: redeemed.familyName);
  }

  List<PendingJoin> _convert(List<net.PendingJoin> joins) => [
        for (final j in joins)
          PendingJoin(deviceId: j.deviceId, deviceName: j.name, kind: j.kind, words: j.matchingWords),
      ];

  /// Where a joiner can reach this device: the hub when there is one, else this device itself
  /// on the same Wi-Fi for the next 15 minutes.
  Future<List<Uri>> _reachableHubs() async {
    if (network.isHub && network.localHub.addresses.isNotEmpty) {
      return [for (final a in network.localHub.addresses) HubClient.syncUri(a)];
    }
    if (network.hubs.isNotEmpty) return network.hubs;
    final direct = await local.serveTemporarily(_node);
    return [?direct];
  }

  Future<T> _open<T>(Future<T> Function() open) async {
    try {
      return await open();
    } on PairingException {
      rethrow;
    } on Object {
      throw const PairingException(
        "Couldn't reach the other device. Check that both are on the same Wi-Fi, or that the hub is on.",
      );
    }
  }

  void _follow(net.JoinAttempt attempt, {required List<Uri> hubs}) {
    // Whether the request reached the family, so it can be waited on again after a disconnect.
    var asked = false;
    attempt.stages.listen((stage) {
      if (stage == net.JoinStage.waitingForApproval || stage == net.JoinStage.syncing) asked = true;
    });
    _status.add(const JoinStatus(JoinState.waiting));
    attempt.completed.then((_) async {
      _status.add(const JoinStatus(JoinState.approved));
      for (final hub in hubs) {
        await network.addHub(hub.toString());
      }
      await network.start();
    }, onError: (Object error) {
      final reason = error is net.JoinException ? error.reason : '';
      if (asked && attempt.stage != net.JoinStage.rejected && network.canAwaitApproval) {
        // The request reached the family; wait for the approval on a new connection.
        _status.add(const JoinStatus(JoinState.waiting));
        unawaited(network.start());
        return;
      }
      _status.add(switch (attempt.stage) {
        net.JoinStage.rejected => JoinStatus(
            JoinState.declined,
            message: reason == 'declined'
                ? 'A parent turned this device away.'
                : 'The code was wrong, used or expired. Ask for a new one.',
          ),
        _ => const JoinStatus(
            JoinState.failed,
            message: 'The connection to the other device ended before a parent approved it. Try again.',
          ),
      });
    });
  }
}
