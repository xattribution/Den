import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' as net;

import 'den_network.dart';
import 'local_stub.dart' if (dart.library.io) 'local_io.dart' as local;
import 'pairing.dart';

/// [PairingService] on den_net: QR invites and spoken codes over the hub, the relay's
/// rendezvous, or (with neither) a direct connection on the same Wi-Fi.
class NetPairing extends PairingService {
  NetPairing(this.network);

  final DenNetwork network;
  final StreamController<JoinStatus> _status = StreamController.broadcast();

  net.SyncNode get _node => network.node;

  @override
  Stream<JoinStatus> get joinStatus => _status.stream;

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

  List<PendingJoin> _convert(List<net.PendingJoin> joins) => [
        for (final j in joins)
          PendingJoin(deviceId: j.deviceId, deviceName: j.name, kind: j.kind, words: j.matchingWords),
      ];

  /// Where a joiner can reach this device: the hub when there is one, else this device itself
  /// on the same Wi-Fi for the next 15 minutes.
  Future<List<Uri>> _reachableHubs() async {
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
    _status.add(const JoinStatus(JoinState.waiting));
    attempt.completed.then((_) async {
      _status.add(const JoinStatus(JoinState.approved));
      for (final hub in hubs) {
        await network.addHub(hub.toString());
      }
      await network.start();
    }, onError: (Object error) {
      final reason = error is net.JoinException ? error.reason : '';
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
