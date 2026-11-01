import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' as net;

import 'den_network.dart';
import 'hub_api.dart';
import 'hub_client.dart';
import 'hub_flows.dart';
import 'local_stub.dart' if (dart.library.io) 'local_io.dart' as local;
import 'pairing.dart';
import 'screen_code_flow.dart';
import '../capabilities.dart';

/// The parent's own 12 recovery words, checked by the family's hub: confirming signs this
/// device's recovery proof with them and asks with it.
class _WordsRecovery extends RecoverySession {
  _WordsRecovery(this._pairing, this._attempt, this._who, this._sync, this._name);

  final NetPairing _pairing;
  final net.JoinAttempt _attempt;
  final net.RecoveringAs _who;
  final Uri _sync;
  final String _name;

  @override
  String get memberName => _who.name;

  @override
  Marker? get marker => Marker.parse(_who.marker);

  @override
  String? get picture => _who.picture;

  @override
  String? get familyName => _who.familyName;

  @override
  bool get byHub => false;

  @override
  Future<JoinTicket> confirm() async {
    try {
      await _attempt.confirmRecovery(deviceName: _name);
    } on Object {
      throw const PairingException("Lost touch with the family's hub. Try again.");
    }
    return _pairing._joined(_attempt, _sync, _who.familyId, _who.familyName);
  }

  @override
  Future<void> cancel() => _attempt.cancel();
}

/// Four words from whoever runs the hub: the hub signed this device's recovery proof already;
/// confirming joins with it.
class _HubRecovery extends RecoverySession {
  _HubRecovery(this._pairing, this._redeemed, this._proof, this._sync, this._name, this._kind);

  final NetPairing _pairing;
  final RedeemedRecovery _redeemed;
  final RecoveryProof _proof;
  final Uri _sync;
  final String _name;
  final DeviceKind _kind;

  @override
  String get memberName => _redeemed.memberName;

  @override
  String? get familyName => _redeemed.familyName;

  @override
  bool get byHub => true;

  @override
  Future<JoinTicket> confirm() async {
    final net.Invite invite;
    try {
      invite = await net.Invite.parse(_redeemed.invite);
    } on FormatException {
      throw const PairingException('These words have expired. Ask whoever runs your hub for new ones.');
    }
    final channel = await _pairing._open(() => net.connectWebSocket(_sync));
    final attempt = await _pairing._node.joinWithRecoveryProof(channel, invite, _proof, deviceName: _name, kind: _kind);
    return _pairing._joined(attempt, _sync, invite.familyId, _redeemed.familyName);
  }

  @override
  Future<void> cancel() async {}
}

/// What someone typed or pasted on "I lost my phone": their 12 recovery words, or the four
/// words (or the whole link, `https://<hub>/#/recover/<w>-<w>-<w>-<w>`) from whoever runs the
/// hub, with the hub's address when the link carried it.
({List<String>? words, String? code, Uri? hub}) recoveryInput(String text) {
  var rest = text.trim();
  Uri? hub;
  final at = rest.indexOf('#/recover/');
  if (at >= 0) {
    final base = Uri.tryParse(rest.substring(0, at));
    if (base != null && base.host.isNotEmpty) hub = Uri(scheme: base.scheme, host: base.host, port: base.port);
    rest = Uri.decodeComponent(rest.substring(at + '#/recover/'.length));
  }
  final words = net.RecoveryWords.parse(rest);
  return (words: words, code: words == null ? net.normalizeCode(rest) : null, hub: hub);
}

/// The family an invite is to, and the hub that keeps it ([NetPairing.inviteTarget]).
class InviteTarget {
  const InviteTarget({required this.base, required this.familyId, this.familyName});

  /// The hub's HTTP base address, `https://den.example.com`.
  final Uri base;
  final String familyId;
  final String? familyName;
}

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
  HubSetupSession setUpHub(HubInfo hub, String code, {String? expectDevice}) =>
      NetHubSetup(network: network, client: _client, hub: hub, code: code, expectDevice: expectDevice)..run();

  @override
  Future<void> useHub(HubInfo hub) => network.addHub(hub.base.toString());

  // ------------------------------------------------------------------ browsers

  @override
  Future<BrowserLinkSession> linkThisBrowser({required String Function() deviceName}) async {
    final base = servedBy ?? (Capabilities.web ? Uri.base : null);
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

  @override
  Future<void> openLinking() async {
    if (network.hubDevice == null) return;
    final api = HubApi(network);
    try {
      await api.send('POST', '/api/v1/link/window');
    } on HubException {
      // An older hub, or one out of reach: the browser says what to do if linking is closed.
    } finally {
      api.close();
    }
  }

  /// The hub that served this page: [servedBy], or the page's own origin on the web.
  Uri? get _servedBase {
    final base = servedBy ?? (Capabilities.web ? Uri.base : null);
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
  HubSetupSession adoptServingHub(HubInfo hub, String code, {String? expectDevice}) =>
      NetHubSetup(network: network, client: _client, hub: hub, code: code, autoApprove: true, expectDevice: expectDevice)..run();

  /// How long an invite sent as a message works when a parent approves whoever opens it.
  static const inviteLife = Duration(days: 3);

  @override
  Future<InviteMessage> createInvite({String? memberId, bool letIn = true}) async {
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
    // The words are this phone's own; the hub gets only the slot they stretch to.
    final words = net.InviteWords.generate();
    final slot = await net.InviteWords.slot(words);
    final keyed = letIn && memberId != null;
    final key = keyed ? await net.InviteWords.key(words) : null;
    String? keyId;
    HubException? last;
    for (final base in bases) {
      final net.Invite invite;
      try {
        invite = _node.createHubInvite(hub.id, hubs: [HubClient.syncUri(base)], validFor: keyed ? inviteKeyDefaultLife : inviteLife);
      } on StateError {
        throw const PairingException("This device doesn't know the family's hub well enough yet. Wait a moment, then try again.");
      }
      if (key != null && keyId == null) {
        try {
          keyId = await den.createInviteKey(member: memberId, publicKey: key.publicKey, expires: invite.expires.millisecondsSinceEpoch);
        } on PermissionDenied catch (e) {
          throw PairingException(e.message);
        } on InvalidInput catch (e) {
          throw PairingException(e.message);
        }
      }
      final grant = await net.InviteGrant.sign(
        invite,
        keys: den.keys,
        context: memberId == null ? 'invite' : 'invite:$memberId',
      );
      try {
        final made = await _createWhenSynced(base, {...grant.toJson(), 'slot': slot, if (key != null) 'key': key.publicKey});
        final family = den.family?.name ?? 'the family';
        final forName = memberId == null ? null : den.member(memberId)?.name;
        if (!made.bySlot) {
          // An older hub picked words of its own; the key would go unused, so take it back.
          if (keyId != null) unawaited(den.withdrawInviteKey(keyId).catchError((Object _) {}));
          return InviteMessage(
            words: made.words,
            link: made.link,
            expires: made.expires,
            familyName: family,
            qr: invite.toUrl(),
            forName: forName,
          );
        }
        return InviteMessage(
          words: words.split(' '),
          link: net.DenLink(kind: net.DenLinkKind.family, words: words).link(made.link),
          expires: made.expires,
          familyName: family,
          qr: invite.toUrl(),
          forName: forName,
          letsIn: made.preapproved,
          inviteKey: made.preapproved ? keyId : null,
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

  /// Sends the invite, waiting a moment while its key travels to the hub (`409 not_synced`).
  Future<HubInvite> _createWhenSynced(Uri base, Map<String, Object?> body) async {
    for (var i = 0;; i++) {
      try {
        return await _client.createInvite(base, body);
      } on HubException catch (e) {
        if (e.code != 'not_synced' || i >= 30) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  /// Invites redeemed already, by hub and words, so "Join" after "Join the Riveras as Leo?"
  /// doesn't ask again.
  final Map<String, RedeemedInvite> _redeemed = {};

  /// What [code] opens at [base]: by the slot the words stretch to, which every hub that keeps
  /// slots answers (the app's own invites, and words a hub chose, which it stretches itself).
  /// The words themselves go only to an older hub that says it doesn't know slots: a hub that
  /// knows them but holds no such slot never sees the words, which carry the invite's key.
  Future<RedeemedInvite> _redeem(Uri base, String code) async {
    final at = '$base $code';
    final known = _redeemed[at];
    if (known != null) return known;
    RedeemedInvite redeemed;
    try {
      redeemed = await _client.redeemInvite(base, slot: await net.InviteWords.slot(code));
    } on HubException catch (e) {
      if (e.code == 'not_found') {
        throw const PairingException(
          "That code isn't right, or the invite has expired. Ask for a new invite.",
          reason: PairingException.unknownCode,
        );
      }
      // An older hub that only knows words.
      if (e.code != 'invalid_input') rethrow;
      try {
        redeemed = await _client.redeemInvite(base, code: code);
      } on HubException catch (again) {
        if (again.code == 'not_found') {
          throw const PairingException(
            "That code isn't right, or the invite has expired. Ask for a new invite.",
            reason: PairingException.unknownCode,
          );
        }
        throw PairingException(again.code == 'not_ready' ? "This hub isn't in a family yet. Start your family first." : again.message);
      }
    }
    return _redeemed[at] = redeemed;
  }

  Uri _inviteBase(String? hubUrl) {
    final base = hubUrl == null || hubUrl.trim().isEmpty ? _servedBase : HubClient.baseFor(hubUrl);
    if (base == null) throw const PairingException("Type the hub's address too. It's the start of the invite's link.");
    return base;
  }

  /// Which family [words] are an invite to, at the hub at [hubUrl] (or the one that served this
  /// page), before anything is written: for a device already in a family, which starts the
  /// family's own engine under its id before it joins ([shareRedeemed] hands the answer on, so
  /// the hub isn't asked twice).
  Future<InviteTarget> inviteTarget(String words, {String? hubUrl}) async {
    final code = net.normalizeCode(words);
    if (code == null) {
      throw const PairingException("Those aren't the four words from an invite. Check them against the message.");
    }
    final base = _inviteBase(hubUrl);
    final redeemed = await _redeem(base, code);
    final net.Invite invite;
    try {
      invite = await net.Invite.parse(redeemed.invite);
    } on FormatException {
      throw const PairingException('This invite has expired. Ask for a new one.');
    }
    return InviteTarget(base: base, familyId: invite.familyId, familyName: redeemed.familyName);
  }

  /// Hands [other] the invites this one redeemed already, so it joins with them without asking
  /// the hub again.
  void shareRedeemed(NetPairing other) => other._redeemed.addAll(_redeemed);

  @override
  Future<InvitePeek> peekInvite(String words, {String? hubUrl}) async {
    final code = net.normalizeCode(words);
    if (code == null) {
      throw const PairingException("Those aren't the four words from an invite. Check them against the message.");
    }
    final base = _inviteBase(hubUrl);
    final redeemed = await _redeem(base, code);
    return InvitePeek(
      familyName: redeemed.familyName,
      memberName: redeemed.memberName,
      marker: Marker.parse(redeemed.memberMarker),
      picture: redeemed.memberPicture,
      letsIn: redeemed.preapproved,
      server: base.host,
    );
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
    final base = _inviteBase(hubUrl);
    final redeemed = await _redeem(base, code);
    final net.Invite invite;
    try {
      invite = await net.Invite.parse(redeemed.invite);
    } on FormatException {
      throw const PairingException('This invite has expired. Ask for a new one.');
    }
    final sync = HubClient.syncUri(base);
    final channel = await _open(() => net.connectWebSocket(sync));
    if (redeemed.preapproved) {
      // The words carry the invite's key: this device lets itself in with it.
      final attempt = await _node.joinWithInviteKey(
        channel,
        await net.InviteWords.key(code),
        deviceName: (name) => deviceName(name ?? redeemed.memberName),
        kind: kind,
        expectFamily: invite.familyId,
        expectDevice: invite.inviterDevice,
        expectPubkey: invite.inviterPubkey,
      );
      await network.rememberJoin(invite.inviterDevice, sync);
      _follow(attempt, hubs: [sync]);
      return JoinTicket(familyId: invite.familyId, familyName: redeemed.familyName, admitted: true);
    }
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

  // ------------------------------------------------------------------ kitchen screens

  @override
  Future<ScreenCodeSession> showScreenCode({String? hubUrl, required String deviceName, required DeviceKind kind}) async {
    final typed = hubUrl == null || hubUrl.trim().isEmpty ? null : HubClient.baseFor(hubUrl);
    final base = typed ?? _servedBase;
    if (base == null) throw const PairingException("Type your family's Den address. A parent can see it in Settings.");
    final session = NetScreenCode(network: network, client: _client, hub: base, deviceName: deviceName, kind: kind);
    await session.start();
    return session;
  }

  static const _wrongScreenCode = "That code isn't right, or it ran out. Check the code on the screen and try again.";

  @override
  Future<ScreenAsk> findScreen(String code) async {
    final normalized = net.ScreenCode.normalize(code);
    if (normalized == null) {
      throw const PairingException("That isn't a screen's code. It's 8 letters and numbers, like K7QM-3RXA.");
    }
    if (network.hubDevice == null && !network.isHub) {
      throw const PairingException("Kitchen screens join through the family's hub. Add the hub first: Settings, Advanced, Hub and sync.");
    }
    final keys = await net.ScreenCode.derive(normalized);
    final api = HubApi(network);
    final Map<String, Object?> json;
    try {
      json = await api.send('POST', '/api/v1/screens/find', body: {'slot': keys.slot});
    } on HubException catch (e) {
      throw PairingException(e.code == 'not_found' ? _wrongScreenCode : e.message);
    } finally {
      api.close();
    }
    final pubkey = json['pubkey'], xpub = json['xpub'], name = json['name'], kind = json['kind'], tag = json['tag'];
    if (pubkey is! String || xpub is! String || name is! String || kind is! String || tag is! String) {
      throw const PairingException("The hub's answer was missing something. Try again.");
    }
    final screenKind = DeviceKind.values.asNameMap()[kind];
    if (screenKind == null || screenKind == DeviceKind.hub) throw const PairingException(_wrongScreenCode);
    // The key is the one the screen showing this code made, whatever the hub says.
    final expected = await keys.screenTag(pubkey: pubkey, xpub: xpub, name: name, kind: kind);
    final device = deviceIdOf(pubkey);
    if (!net.ScreenCodeKeys.same(tag, expected) || device == null) throw const PairingException(_wrongScreenCode);
    return ScreenAsk(
      name: name,
      kind: screenKind,
      device: device,
      pubkey: pubkey,
      xpub: xpub,
      code: normalized,
      expires: (json['expires_ms'] as num?)?.toInt() ?? 0,
    );
  }

  /// How long the parent's phone waits for the screen's join request after Add.
  static const screenAnswerWait = Duration(seconds: 90);

  @override
  Future<void> addScreen(ScreenAsk screen, {required String name}) async {
    final den = network.den;
    final hub = network.isHub ? den.deviceId : network.hubDevice?.id;
    final family = den.familyId, founder = den.founderPubkey;
    if (hub == null || family == null || founder == null) {
      throw const PairingException("Kitchen screens join through the family's hub. Add the hub first: Settings, Advanced, Hub and sync.");
    }
    final label = name.trim().isEmpty ? screen.name : name.trim();
    final keys = await net.ScreenCode.derive(screen.code);
    final api = HubApi(network);
    try {
      await api.send('POST', '/api/v1/screens/accept', body: {
        'slot': keys.slot,
        'family': family,
        'founder': founder,
        'hub': hub,
        'name': label,
        'tag': await keys.familyTag(family: family, founder: founder, hub: hub, pubkey: screen.pubkey, name: label),
      });
      // The screen checks the answer, asks to join and hands its request to the hub.
      final deadline = DateTime.now().add(screenAnswerWait);
      Change? request;
      while (request == null) {
        final json = await api.send('POST', '/api/v1/screens/request', body: {'slot': keys.slot});
        final raw = json['change'];
        if (json['state'] == 'requested' && raw is Map) {
          try {
            request = Change.fromJson(raw.cast<String, Object?>());
          } on Object {
            throw const PairingException("The screen's answer wasn't one Den can use. Get a new code on the screen and try again.");
          }
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw const PairingException("The screen didn't answer. Check it's on and online, get a new code there, and try again.");
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
      // Only the key the parent saw, asking for nothing but a shared screen nobody owns.
      if (!await net.isScreenJoinRequest(request, pubkey: screen.pubkey, xpub: screen.xpub, name: label, kind: screen.kind.name)) {
        throw const PairingException("The screen's answer didn't match its code. Get a new code on the screen and try again.");
      }
      await den.ingest([request]);
      final asked = den.device(screen.device);
      if (asked == null || asked.pubkey != screen.pubkey || asked.revoked) {
        throw const PairingException("Den couldn't take the screen's request. Get a new code on the screen and try again.");
      }
      if (!asked.approved) await den.approveDevice(screen.device, mode: DeviceMode.shared);
      if (den.device(screen.device)?.name != label) await den.updateDevice(screen.device, {'name': label});
    } on HubException catch (e) {
      throw PairingException(e.code == 'not_found' ? 'This code ran out. Get a new one on the screen and try again.' : e.message);
    } on PermissionDenied catch (e) {
      throw PairingException(e.message);
    } on InvalidInput catch (e) {
      throw PairingException(e.message);
    } finally {
      api.close();
    }
  }

  // ------------------------------------------------------------------ recovery

  @override
  Future<String> hubRecoveryKey() async {
    if (network.hubDevice == null && !network.isHub) {
      throw const PairingException("Getting back in with the hub's help needs the family's hub. Add it first.");
    }
    final api = HubApi(network);
    try {
      final json = await api.send('GET', '/api/v1/recovery/key', missing: "The family's hub can't help yet. Update it, then try again.");
      final key = json['key'];
      if (key is! String) throw const PairingException("The hub's answer had no key in it. Try again.");
      return key;
    } on HubException catch (e) {
      throw PairingException(e.message);
    } finally {
      api.close();
    }
  }

  @override
  Future<RecoverySession> startRecovery(
    String text, {
    String? hubUrl,
    required String Function(String name) deviceName,
    required DeviceKind kind,
  }) async {
    final typed = recoveryInput(text);
    final base = (hubUrl == null || hubUrl.trim().isEmpty ? null : HubClient.baseFor(hubUrl)) ?? typed.hub ?? _servedBase;
    if (base == null) throw const PairingException("Type your hub's address too. Whoever runs it knows it.");
    final sync = HubClient.syncUri(base);
    final words = typed.words;
    if (words != null) {
      final channel = await _open(() => net.connectWebSocket(sync));
      final attempt = await _node.joinWithRecoveryWords(channel, words, deviceName: deviceName(''), kind: kind);
      final net.RecoveringAs who;
      try {
        who = await attempt.recoveringAs.timeout(const Duration(seconds: 30));
      } on net.JoinException catch (e) {
        throw PairingException(e.reason == 'bad-proof'
            ? "Those words don't belong to anyone in this family. Check them against where you saved them."
            : "Couldn't check the words with the family's hub. Try again.");
      } on TimeoutException {
        await attempt.cancel();
        throw const PairingException("The family's hub didn't answer. Check the connection, then try again.");
      }
      return _WordsRecovery(this, attempt, who, sync, deviceName(who.name));
    }
    final code = typed.code;
    if (code == null) throw const PairingException('Type your 12 recovery words, or the 4 words from whoever runs your hub.');
    final RedeemedRecovery redeemed;
    try {
      redeemed = await _client.redeemRecovery(base, code, network.den.keys.pubkey);
    } on HubException catch (e) {
      throw PairingException(e.code == 'not_found'
          ? "Those words aren't right, or they've been used or expired. Ask whoever runs your hub for new ones."
          : e.message);
    }
    final proof = RecoveryProof.parse(redeemed.proof);
    if (proof == null) throw const PairingException("The hub's answer was missing something. Try again.");
    return _HubRecovery(this, redeemed, proof, sync, deviceName(redeemed.memberName), kind);
  }

  Future<JoinTicket> _joined(net.JoinAttempt attempt, Uri sync, String familyId, String? familyName) async {
    await network.rememberJoin(attempt.peer.deviceId, sync);
    _follow(attempt, hubs: [sync]);
    return JoinTicket(familyId: familyId, familyName: familyName);
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
        net.JoinStage.rejected when attempt.via == 'key' => JoinStatus(
            JoinState.declined,
            message: reason == 'rate-limited'
                ? 'Too many tries from here. Wait ten minutes, then try again.'
                : 'This invite was used already, or a parent took it back. Ask for a new one.',
          ),
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
