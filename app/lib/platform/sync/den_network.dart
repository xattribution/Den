import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_hub.dart';
import 'local_stub.dart' if (dart.library.io) 'local_io.dart' as local;
import '../capabilities.dart';

/// This device's link to the rest of the family: one [SyncNode] for the engine, and a
/// [SyncClient] that keeps it live with the hub over the home network or, away from home,
/// through the relay. Without a hub, devices still pair and sync directly. On desktops and
/// Android a parent can make this device the hub itself ([keepOnline]).
class DenNetwork extends ChangeNotifier {
  DenNetwork(
    this.den, {
    List<Uri> hubs = const [],
    this.relay,
    LocalHub? localHub,
    String? joinHub,
    String? turnedAway,
    Map<String, HubSighting> seen = const {},
  })  : node = SyncNode(den),
        localHub = localHub ?? LocalHub.create(),
        _hubs = [...hubs],
        _joinHub = joinHub,
        _turnedAway = turnedAway,
        _seen = {...seen} {
    this.localHub.addListener(notifyListeners);
  }

  static const _hubsKey = 'den.hubs';
  static const _relayKey = 'den.relay';
  static const _joinHubKey = 'den.joinHub';
  static const _turnedAwayKey = 'den.turnedAway';
  static const _seenKey = 'den.hubsSeen';

  /// Restores the saved hub addresses and relay for this device.
  static Future<DenNetwork> load(Den den) async {
    final prefs = await SharedPreferences.getInstance();
    final relay = prefs.getString(_relayKey);
    return DenNetwork(
      den,
      hubs: [...?prefs.getStringList(_hubsKey)?.map(Uri.tryParse).whereType<Uri>()],
      relay: relay == null ? null : Uri.tryParse(relay),
      joinHub: prefs.getString(_joinHubKey),
      turnedAway: prefs.getString(_turnedAwayKey),
      seen: HubSighting.decode(prefs.getString(_seenKey)),
    );
  }

  final Den den;
  final SyncNode node;

  /// The hub this app runs in-process when this device is the family's hub.
  final LocalHub localHub;
  final List<Uri> _hubs;

  /// The device this one asked to join through (the family's hub), so a device still waiting
  /// for approval reconnects to it, and only to it, after Den was closed.
  String? _joinHub;

  /// The device id a parent turned away while it waited, so it stops asking (a new invite, with
  /// new keys, is the way back in).
  String? _turnedAway;

  /// When and where this device last synced with each of the family's hubs, by device id.
  final Map<String, HubSighting> _seen;

  /// The relay this family uses to reach the hub from outside the house, if any.
  Uri? relay;

  SyncClient? _client;
  StreamSubscription<SyncStatus>? _statusSub;
  SyncStatus _status = const SyncStatus(SyncState.offline);
  bool _switching = false;
  bool _disposed = false;

  SyncStatus get status => _status;

  /// Whether a connection to the hub is being kept or tried; false with no hub to reach.
  bool get connecting => _client != null;

  /// The node pairing goes through: the in-process hub's while it runs (so joiners reaching the
  /// hub find this device's invites), else this device's own.
  SyncNode get activeNode => localHub.node ?? node;

  /// Saved hub sync addresses, `ws://host:47733/ws` form.
  List<Uri> get hubs => List.unmodifiable(_hubs);

  /// The family's hub device, once one has been approved: the first of [hubDevices].
  Device? get hubDevice => hubDevices.firstOrNull;

  /// The family's approved hubs other than this device, the one to use first: the hub this
  /// device is synced with now, then the one it synced with most recently, then the newest
  /// approved. After "reset the hub, keep the family" there are two, often with the same name,
  /// until a parent removes the old one; name order would pick the dead one half the time.
  List<Device> get hubDevices {
    final live = _status.state == SyncState.live || _status.state == SyncState.syncing ? _status.device : null;
    Hlc approvedAt(Device d) => d.rec.fieldTimes['approved'] ?? d.rec.updated;
    return den.devices.where((d) => d.mode == DeviceMode.hub && d.approved && !d.revoked && d.id != den.deviceId).toList()
      ..sort((a, b) {
        if (a.id == live || b.id == live) return a.id == live ? -1 : 1;
        final seen = (_seen[b.id]?.at ?? 0).compareTo(_seen[a.id]?.at ?? 0);
        return seen != 0 ? seen : approvedAt(b).compareTo(approvedAt(a));
      });
  }

  /// When this device last synced with [hub], or null if it never has. "Now" while it is.
  DateTime? lastSeen(String hub) {
    if (_status.device == hub && _status.state == SyncState.live) return DateTime.fromMillisecondsSinceEpoch(den.now());
    final at = _seen[hub]?.at;
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  /// Whether this device is synced with [hub] right now.
  bool syncedWith(String hub) => _status.device == hub && _status.state == SyncState.live;

  /// The family's hubs (other than [except]) that a hub at [address] would replace: those this
  /// device last reached at the same host and port and, for hubs it never recorded an address
  /// for, all of them when the address is one already saved here.
  List<Device> hubsAt(Uri address, {String? except}) {
    bool same(Uri a) => a.host == address.host && _port(a) == _port(address);
    final saved = _hubs.any(same);
    return [
      for (final d in hubDevices)
        if (d.id != except && (_seen[d.id]?.address == null ? saved : same(_seen[d.id]!.address!))) d,
    ];
  }

  static int _port(Uri u) => u.hasPort ? u.port : (u.scheme == 'https' || u.scheme == 'wss' ? 443 : 80);

  /// Whether this device is itself the family's hub.
  bool get isHub => den.thisDevice?.mode == DeviceMode.hub;

  /// Starts syncing when this device belongs to an approved family, or starts the in-process hub
  /// when this device is the hub. Safe to call again after the hub or relay changes.
  Future<void> start() async {
    if (_disposed) return;
    await _stopClient();
    if (_disposed) return;
    if (!den.hasFamily) {
      _setStatus(const SyncStatus(SyncState.offline));
      return;
    }
    if (!den.isApproved) {
      _awaitApproval();
      return;
    }
    if (isHub) {
      if (LocalHub.supported) await localHub.start(den, relay: relay);
      _setStatus(const SyncStatus(SyncState.live));
      return;
    }
    final hubs = hubDevices;
    final usual = hubs.isEmpty ? null : _seen[hubs.first.id]?.address;
    // Direct addresses aren't pinned to one hub: any hub the family approved may answer there,
    // and one it removed is told so and tried last (SyncClient). The address the preferred hub
    // last answered at goes first; relay tunnels name each hub.
    final endpoints = <Uri>{
      ...?_servingHub(),
      if (usual != null && _hubs.contains(usual)) usual,
      ..._hubs,
      ...await local.discoverHubs(den.familyId!),
      if (relay != null)
        for (final h in hubs) relayConnectUri(relay!, h.id),
    }.toList();
    if (_disposed) return;
    if (endpoints.isEmpty) {
      _setStatus(const SyncStatus(SyncState.offline, lastError: 'no hub'));
      return;
    }
    _run(SyncClient(node: node, endpoints: endpoints));
  }

  void _run(SyncClient client) {
    _client = client;
    _statusSub = client.statusChanges.listen(_setStatus);
    client.start();
  }

  /// A device that asked to join waits connected to the device it asked through, so a parent's
  /// approval reaches it whenever they give it, also after Den was closed and opened again. The
  /// connection is pinned to that device: this one doesn't know the family's devices yet.
  void _awaitApproval() {
    if (turnedAway) {
      _setStatus(const SyncStatus(SyncState.offline, lastError: 'declined'));
      return;
    }
    final pin = _joinHub;
    final me = den.thisDevice;
    final endpoints = <Uri>{...?_servingHub(), ..._hubs}.toList();
    if (pin == null || me == null || me.revoked || endpoints.isEmpty) {
      _setStatus(const SyncStatus(SyncState.offline));
      return;
    }
    _run(SyncClient(node: node, endpoints: endpoints, expectDevice: pin));
  }

  /// Remembers that this device asked to join through [device] at [sync], so it can wait for
  /// approval there again later.
  Future<void> rememberJoin(String device, Uri? sync) async {
    _joinHub = device;
    if (sync != null && !_hubs.contains(sync)) _hubs.add(sync);
    await _save();
  }

  /// Whether a parent turned this device away while it waited for approval: the device it waits
  /// on says so as soon as it connects, and this device stops asking.
  bool get turnedAway => !den.isApproved && _turnedAway != null && _turnedAway == den.deviceId;

  Future<void> _turnAway() async {
    _turnedAway = den.deviceId;
    await _stopClient();
    _setStatus(const SyncStatus(SyncState.offline, lastError: 'declined'));
    await _save();
  }

  /// Whether a device waiting for approval knows where to wait.
  bool get canAwaitApproval => _joinHub != null && (_hubs.isNotEmpty || _servingHub() != null);

  /// "Keep the family online": makes this device the family's hub and runs the hub in-process,
  /// or turns it back into its owner's personal device. Parents only; the engine refuses others.
  /// Throws [InvalidInput] or [PermissionDenied] with a message for people.
  Future<void> keepOnline(bool on) async {
    if (_switching) return;
    _switching = true;
    try {
      final device = den.thisDevice;
      if (device == null) throw const InvalidInput('This device isn\'t part of a family yet');
      if (on) {
        if (!LocalHub.supported) throw const InvalidInput('This device can\'t run the hub. Use a computer or an Android tablet.');
        if (isHub && localHub.state == LocalHubState.running) return;
        await _stopClient();
        await den.setThisDeviceMode(DeviceMode.hub);
        await localHub.start(den, relay: relay);
        if (localHub.state == LocalHubState.failed) {
          // Don't leave the family pointing at a hub that isn't running.
          await den.setThisDeviceMode(DeviceMode.personal);
          await start();
        } else {
          _setStatus(const SyncStatus(SyncState.live));
        }
      } else {
        await localHub.stop();
        if (isHub) {
          await den.setThisDeviceMode(DeviceMode.personal);
        }
        await start();
      }
    } finally {
      _switching = false;
      notifyListeners();
    }
  }

  /// Adds a hub address typed by a person or found in an invite, saves it and reconnects (also
  /// when it was saved already: a new hub may answer there now).
  Future<void> addHub(String address) async {
    if (_disposed) return;
    final uri = syncUriFor(address);
    if (uri == null) return;
    if (!_hubs.contains(uri)) {
      _hubs.add(uri);
      await _save();
    }
    await start();
  }

  /// Forgets a saved hub address.
  Future<void> removeHub(Uri uri) async {
    if (!_hubs.remove(uri)) return;
    await _save();
    await start();
  }

  Future<void> setRelay(String? address) async {
    relay = address == null || address.trim().isEmpty ? null : Uri.tryParse(address.trim());
    await _save();
    await start();
  }

  /// The family hub's HTTP addresses, best first: this device's own hub when it is the hub, the
  /// server a browser page came from, saved addresses, then hubs answering on the home network.
  /// Empty when the family has no hub.
  Future<List<Uri>> hubBases() async {
    if (!den.hasFamily || (!isHub && hubDevice == null)) return const [];
    Uri http(Uri sync) => Uri(scheme: sync.scheme == 'wss' ? 'https' : 'http', host: sync.host, port: sync.port);
    final live = _status.state == SyncState.live ? _status.endpoint : null;
    return <Uri>{
      if (isHub) ...localHub.addresses,
      if (live != null && (live.scheme == 'ws' || live.scheme == 'wss') && live.path == '/ws') http(live),
      for (final s in [...?_servingHub(), ..._hubs]) http(s),
      for (final s in await local.discoverHubs(den.familyId!)) http(s),
    }.toList();
  }

  /// Turns "192.168.1.20", "hub.local:47733" or "https://den.example.com" into the hub's sync
  /// WebSocket address.
  static Uri? syncUriFor(String address) {
    var text = address.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'http://$text';
    final parsed = Uri.tryParse(text);
    if (parsed == null || parsed.host.isEmpty) return null;
    final secure = parsed.scheme == 'https' || parsed.scheme == 'wss';
    return parsed.replace(
      scheme: secure ? 'wss' : 'ws',
      port: parsed.hasPort ? parsed.port : (secure ? 443 : hubPort),
      path: '/ws',
      query: null,
      fragment: null,
    );
  }

  /// In a browser served by the hub, the hub is wherever the page came from.
  List<Uri>? _servingHub() {
    if (!Capabilities.web) return null;
    final base = Uri.base;
    if (base.host.isEmpty) return null;
    return [base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '/ws', query: null, fragment: null)];
  }

  /// A sentence for Settings and the top bar.
  String describe() {
    if (isHub) {
      return switch (localHub.state) {
        LocalHubState.running => localHub.connected == 0
            ? "This device is the family's hub. No other devices are connected right now."
            : "This device is the family's hub. ${localHub.connected} ${localHub.connected == 1 ? 'device is' : 'devices are'} connected.",
        LocalHubState.starting => "Starting the family's hub on this device",
        LocalHubState.failed => localHub.error ?? "The hub on this device couldn't start.",
        LocalHubState.off => LocalHub.supported
            ? "This device is set to be the family's hub, but the hub isn't running."
            : "This device is set to be the family's hub, but it can't run one. Turn that off from a parent's phone.",
      };
    }
    final hub = den.device(_status.device ?? '')?.name ?? hubDevice?.name ?? 'the hub';
    return switch (_status.state) {
      SyncState.live => 'Up to date with $hub',
      SyncState.syncing => 'Catching up with $hub',
      SyncState.connecting => 'Connecting to $hub',
      SyncState.stopped || SyncState.offline when (_status.lastError ?? '').contains('access-ended') =>
        'Your access to the family ended. Ask a parent to invite you again.',
      SyncState.stopped || SyncState.offline when _status.lastError == 'no hub' =>
        'No hub yet. Devices sync with each other when they meet.',
      SyncState.stopped || SyncState.offline => "Can't reach $hub. Changes are saved here and sync later.",
    };
  }

  void _setStatus(SyncStatus status) {
    if (_disposed) return;
    final before = _status;
    _status = status;
    _noteSighting(before, status);
    notifyListeners();
    final error = status.lastError;
    if ((error == 'declined' || error == 'revoked') && den.hasFamily && !den.isApproved && !turnedAway) {
      unawaited(_turnAway());
    }
  }

  /// Remembers when and where this device was last synced with a hub: as it goes live, and
  /// as the connection ends.
  void _noteSighting(SyncStatus before, SyncStatus now) {
    final wasLive = before.state == SyncState.live ? before : null;
    final sighting = now.state == SyncState.live ? now : wasLive;
    final hub = sighting?.device;
    if (sighting == null || hub == null || (wasLive != null && now.state == SyncState.live && before.device == hub)) return;
    final endpoint = sighting.endpoint;
    final direct = endpoint != null && (endpoint.scheme == 'ws' || endpoint.scheme == 'wss') && endpoint.path == '/ws';
    _seen[hub] = HubSighting(den.now(), direct ? endpoint : _seen[hub]?.address);
    unawaited(_saveSeen());
  }

  Future<void> _saveSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_seenKey, HubSighting.encode(_seen));
    } on Object {
      // Only a preference for which hub to try first.
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hubsKey, [for (final h in _hubs) h.toString()]);
    final pin = _joinHub;
    if (pin == null) {
      await prefs.remove(_joinHubKey);
    } else {
      await prefs.setString(_joinHubKey, pin);
    }
    final away = _turnedAway;
    if (away == null) {
      await prefs.remove(_turnedAwayKey);
    } else {
      await prefs.setString(_turnedAwayKey, away);
    }
    if (relay == null) {
      await prefs.remove(_relayKey);
    } else {
      await prefs.setString(_relayKey, relay.toString());
    }
  }

  Future<void> _stopClient() async {
    await _statusSub?.cancel();
    _statusSub = null;
    final client = _client;
    _client = null;
    await client?.stop();
  }

  /// Stops syncing and closes the node without touching the in-process hub: the end of a
  /// background refresh, which never starts one.
  Future<void> close() async {
    _disposed = true;
    localHub.removeListener(notifyListeners);
    await _stopClient();
    await node.close();
  }

  @override
  void dispose() {
    _disposed = true;
    localHub.removeListener(notifyListeners);
    unawaited(localHub.stop());
    unawaited(_stopClient());
    unawaited(node.close());
    super.dispose();
  }
}

/// When this device last synced with a hub, and the direct address it reached it at (null
/// through the relay).
class HubSighting {
  const HubSighting(this.at, this.address);

  /// Milliseconds since the epoch.
  final int at;
  final Uri? address;

  static Map<String, HubSighting> decode(String? text) {
    if (text == null) return {};
    final out = <String, HubSighting>{};
    try {
      for (final e in (jsonDecode(text) as Map<String, Object?>).entries) {
        final v = e.value;
        if (v is! Map || v['at'] is! int) continue;
        final address = Uri.tryParse(v['address'] as String? ?? '');
        out[e.key] = HubSighting(v['at'] as int, address == null || address.host.isEmpty ? null : address);
      }
    } on Object {
      // A preference; start over.
    }
    return out;
  }

  static String encode(Map<String, HubSighting> seen) => jsonEncode({
        for (final e in seen.entries) e.key: {'at': e.value.at, if (e.value.address != null) 'address': e.value.address.toString()},
      });
}
