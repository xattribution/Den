import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' as net;

import 'den_network.dart';
import 'hub_client.dart';
import 'pairing.dart';

/// A kitchen screen showing its code at the family's hub (`/api/v1/screens`, ARCHITECTURE.md,
/// "Kitchen screen code"), on den_net and the hub.
///
/// It picks the code itself and gives the hub only the code's slot, its keys and the code's
/// tag over them. Once a parent's phone took the code, it checks the phone's tag over the
/// family it joins (so a hub in between can't send it elsewhere), writes its own join request
/// (unapproved, shared, nobody's) and hands it to the hub for the phone. Then it waits on the
/// hub like any device that asked to join, pinned to the hub's device id, until the approval
/// the parent signed on her phone reaches it.
class NetScreenCode extends ScreenCodeSession {
  NetScreenCode({
    required this.network,
    required this.client,
    required this.hub,
    required this.deviceName,
    required this.kind,
    this.every = const Duration(seconds: 2),
  });

  final DenNetwork network;
  final HubClient client;
  @override
  final Uri hub;
  final String deviceName;
  final DeviceKind kind;
  final Duration every;

  String _code = '';
  late net.ScreenCodeKeys _keys;
  String? _secret;
  int _expires = 0;
  ScreenStage _stage = ScreenStage.starting;
  String? _error;
  Timer? _timer;
  bool _busy = false;
  bool _closed = false;

  @override
  String get code => _code;

  @override
  int get expires => _expires;

  @override
  ScreenStage get stage => _stage;

  @override
  String? get error => _error;

  Den get _den => network.den;

  void _set(ScreenStage stage, {String? error}) {
    if (_closed) return;
    _stage = stage;
    _error = error;
    notifyListeners();
  }

  /// Gets a code from the hub and starts asking how it stands. Throws [PairingException] with
  /// words for people when the hub won't give one.
  Future<void> start() async {
    if (_den.hasFamily) throw const PairingException('This device is in a family already.');
    final keys = _den.keys;
    for (var tries = 0;; tries++) {
      final code = net.ScreenCode.generate();
      final derived = await net.ScreenCode.derive(code);
      final Map<String, Object?> made;
      try {
        made = await client.screen(hub, 'code', {
          'slot': derived.slot,
          'pubkey': keys.pubkey,
          'xpub': keys.xpub,
          'name': deviceName,
          'kind': kind.name,
          'tag': await derived.screenTag(pubkey: keys.pubkey, xpub: keys.xpub, name: deviceName, kind: kind.name),
        });
      } on HubException catch (e) {
        // A code someone else's screen holds: pick another.
        if (e.code == 'conflict' && tries < 2) continue;
        throw PairingException(switch (e.code) {
          'not_ready' => "This address isn't a family's Den yet. Start the family first, on a parent's phone.",
          'not_found' || 'no_family' => "This Den can't add screens with a code yet. Ask whoever runs it to update it.",
          _ => e.message,
        });
      }
      _code = code;
      _keys = derived;
      _secret = made['secret'] as String?;
      _expires = (made['expires_ms'] as num?)?.toInt() ?? DateTime.now().add(net.ScreenCode.life).millisecondsSinceEpoch;
      break;
    }
    _set(ScreenStage.waiting);
    _timer = Timer.periodic(every, (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    if (_busy || _closed) return;
    if (_stage == ScreenStage.waiting && DateTime.now().millisecondsSinceEpoch >= _expires) {
      _timer?.cancel();
      _set(ScreenStage.expired);
      return;
    }
    if (_den.isApproved) {
      _done();
      return;
    }
    _busy = true;
    try {
      final status = await client.screen(hub, 'code/status', {'slot': _keys.slot, 'secret': _secret});
      switch (status['state']) {
        case 'accepted' when _stage == ScreenStage.waiting:
          await _join(status);
        case 'accepted' || 'requested':
          if (_stage == ScreenStage.waiting) _set(ScreenStage.joining);
        case 'approved':
          _done();
        case 'declined':
          _timer?.cancel();
          _set(ScreenStage.failed, error: 'A parent removed this screen. Start over to get a new code.');
      }
    } on HubException catch (e) {
      if (_stage == ScreenStage.joining) {
        // The hub forgets the code once the approval reached it: the sync connection brings it.
        if (e.code == 'not_found') _timer?.cancel();
        return;
      }
      _timer?.cancel();
      _set(e.code == 'not_found' ? ScreenStage.expired : ScreenStage.failed, error: e.message);
    } on PairingException catch (e) {
      _timer?.cancel();
      _set(ScreenStage.failed, error: e.message);
    } on Object {
      if (_stage == ScreenStage.joining) return;
      _timer?.cancel();
      _set(ScreenStage.failed, error: "Couldn't reach the family's hub. Check the connection, then get a new code.");
    } finally {
      _busy = false;
    }
  }

  /// A parent's phone took the code: checks what it says to join with came from that phone,
  /// then asks to join and hands the request to the hub.
  Future<void> _join(Map<String, Object?> status) async {
    final family = status['family'], founder = status['founder'], hubDevice = status['hub'];
    final name = status['name'], tag = status['tag'];
    if (family is! String || founder is! String || hubDevice is! String || name is! String || tag is! String) {
      throw const PairingException("The hub's answer was missing something. Get a new code and try again.");
    }
    final expected = await _keys.familyTag(family: family, founder: founder, hub: hubDevice, pubkey: _den.keys.pubkey, name: name);
    if (!net.ScreenCodeKeys.same(tag, expected)) {
      throw const PairingException("The answer didn't come from a parent's phone with this code. Get a new code and try again.");
    }
    if (!_den.hasFamily) {
      await _den.requestJoin(
        familyId: family,
        founderPubkey: founder,
        deviceName: name,
        kind: kind,
        mode: DeviceMode.shared,
      );
    }
    final request = _den.changesSince(const {}).firstWhere((c) => c.type == RecordType.device && c.rid == _den.deviceId);
    await client.screen(hub, 'code/join', {'slot': _keys.slot, 'secret': _secret, 'change': request.toJson()});
    // Waits on the hub for the approval, as any device that asked to join does, also after Den
    // is closed and opened again.
    await network.rememberJoin(hubDevice, HubClient.syncUri(hub));
    unawaited(network.start());
    _set(ScreenStage.joining);
  }

  void _done() {
    if (_stage == ScreenStage.approved) return;
    _timer?.cancel();
    _set(ScreenStage.approved);
    // A fresh connection: the hub now knows this screen and syncs with it at once.
    unawaited(network.start());
  }

  @override
  Future<void> cancel() async => _timer?.cancel();

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    super.dispose();
  }
}
