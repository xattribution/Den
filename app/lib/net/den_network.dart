import 'dart:async';

import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_hub.dart';
import 'local_stub.dart' if (dart.library.io) 'local_io.dart' as local;

/// This device's link to the rest of the family: one [SyncNode] for the engine, and a
/// [SyncClient] that keeps it live with the hub over the home network or, away from home,
/// through the relay. Without a hub, devices still pair and sync directly. On desktops and
/// Android a parent can make this device the hub itself ([keepOnline]).
class DenNetwork extends ChangeNotifier {
  DenNetwork(this.den, {List<Uri> hubs = const [], this.relay, LocalHub? localHub})
      : node = SyncNode(den),
        localHub = localHub ?? LocalHub.create(),
        _hubs = [...hubs] {
    this.localHub.addListener(notifyListeners);
  }

  static const _hubsKey = 'den.hubs';
  static const _relayKey = 'den.relay';

  /// Restores the saved hub addresses and relay for this device.
  static Future<DenNetwork> load(Den den) async {
    final prefs = await SharedPreferences.getInstance();
    final relay = prefs.getString(_relayKey);
    return DenNetwork(
      den,
      hubs: [...?prefs.getStringList(_hubsKey)?.map(Uri.tryParse).whereType<Uri>()],
      relay: relay == null ? null : Uri.tryParse(relay),
    );
  }

  final Den den;
  final SyncNode node;

  /// The hub this app runs in-process when this device is the family's hub.
  final LocalHub localHub;
  final List<Uri> _hubs;

  /// The relay this family uses to reach the hub from outside the house, if any.
  Uri? relay;

  SyncClient? _client;
  StreamSubscription<SyncStatus>? _statusSub;
  SyncStatus _status = const SyncStatus(SyncState.offline);
  bool _switching = false;
  bool _disposed = false;

  SyncStatus get status => _status;

  /// The node pairing goes through: the in-process hub's while it runs (so joiners reaching the
  /// hub find this device's invites), else this device's own.
  SyncNode get activeNode => localHub.node ?? node;

  /// Saved hub sync addresses, `ws://host:47733/ws` form.
  List<Uri> get hubs => List.unmodifiable(_hubs);

  /// The family's hub device, once one has been approved.
  Device? get hubDevice =>
      den.devices.firstWhereOrNull((d) => d.mode == DeviceMode.hub && d.approved && !d.revoked && d.id != den.deviceId);

  /// Whether this device is itself the family's hub.
  bool get isHub => den.thisDevice?.mode == DeviceMode.hub;

  /// Starts syncing when this device belongs to an approved family, or starts the in-process hub
  /// when this device is the hub. Safe to call again after the hub or relay changes.
  Future<void> start() async {
    if (_disposed) return;
    await _stopClient();
    if (_disposed) return;
    if (!den.hasFamily || !den.isApproved) {
      _setStatus(const SyncStatus(SyncState.offline));
      return;
    }
    if (isHub) {
      if (LocalHub.supported) await localHub.start(den, relay: relay);
      _setStatus(const SyncStatus(SyncState.live));
      return;
    }
    final endpoints = <Uri>{
      ...?_servingHub(),
      ..._hubs,
      ...await local.discoverHubs(den.familyId!),
      if (relay != null && hubDevice != null) relayConnectUri(relay!, hubDevice!.id),
    }.toList();
    if (_disposed) return;
    if (endpoints.isEmpty) {
      _setStatus(const SyncStatus(SyncState.offline, lastError: 'no hub'));
      return;
    }
    final client = SyncClient(node: node, endpoints: endpoints, expectDevice: hubDevice?.id);
    _client = client;
    _statusSub = client.statusChanges.listen(_setStatus);
    client.start();
  }

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

  /// Adds a hub address typed by a person or found in an invite, saves it and reconnects.
  Future<void> addHub(String address) async {
    if (_disposed) return;
    final uri = syncUriFor(address);
    if (uri == null || _hubs.contains(uri)) return;
    _hubs.add(uri);
    await _save();
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
    if (!kIsWeb) return null;
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
    final hub = hubDevice?.name ?? 'the hub';
    return switch (_status.state) {
      SyncState.live => 'Up to date with $hub',
      SyncState.syncing => 'Catching up with $hub',
      SyncState.connecting => 'Connecting to $hub',
      SyncState.stopped || SyncState.offline when _status.lastError == 'no hub' =>
        'No hub yet. Devices sync with each other when they meet.',
      SyncState.stopped || SyncState.offline => "Can't reach $hub. Changes are saved here and sync later.",
    };
  }

  void _setStatus(SyncStatus status) {
    if (_disposed) return;
    _status = status;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hubsKey, [for (final h in _hubs) h.toString()]);
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
