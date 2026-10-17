import 'dart:async';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'local_hub.dart';

/// Desktops and Android can keep a hub running; iPhones and iPads stop apps in the background.
bool get localHubSupported => Platform.isAndroid || Platform.isWindows || Platform.isMacOS || Platform.isLinux;

LocalHub createLocalHub({int port = defaultHubPort, bool mdns = true, String? dataDir}) =>
    _IoHub(port: port, mdns: mdns, dataDir: dataDir);

class _IoHub extends LocalHub {
  _IoHub({required this.port, required this.mdns, this.dataDir});

  final int port;
  final bool mdns;
  final String? dataDir;

  DenHub? _hub;
  LocalHubState _state = LocalHubState.off;
  String? _error;
  List<Uri> _addresses = const [];
  int _connected = 0;
  Timer? _tick;

  @override
  LocalHubState get state => _state;

  @override
  String? get error => _error;

  @override
  List<Uri> get addresses => _addresses;

  @override
  int get connected => _connected;

  @override
  SyncNode? get node => _hub?.node;

  @override
  Future<void> start(Den den, {Uri? relay}) async {
    if (_state == LocalHubState.running || _state == LocalHubState.starting) return;
    _state = LocalHubState.starting;
    _error = null;
    notifyListeners();
    try {
      final hub = await DenHub.start(
        den,
        HubConfig(
          port: port,
          dataDir: dataDir ?? await _defaultDataDir(),
          relay: relay,
          name: den.thisDevice?.name ?? 'Den hub',
          mdns: mdns,
          log: HubLog(level: kDebugMode ? LogLevel.info : LogLevel.warn, sink: (line) => debugPrint('hub: $line')),
        ),
      );
      _hub = hub;
      final lan = await _lanAddresses(hub.port);
      // Without a home network (a test machine, say) the hub still answers on this device.
      _addresses = lan.isNotEmpty ? lan : [Uri(scheme: 'http', host: '127.0.0.1', port: hub.port)];
      _state = LocalHubState.running;
      _tick = Timer.periodic(const Duration(seconds: 3), (_) {
        final n = hub.node.peers.length;
        if (n != _connected) {
          _connected = n;
          notifyListeners();
        }
      });
    } on SocketException catch (e) {
      _state = LocalHubState.failed;
      final code = e.osError?.errorCode;
      final inUse = code == 98 || code == 48 || code == 10048 || (e.message.toLowerCase().contains('address already in use'));
      _error = inUse
          ? 'Port $port is already in use, maybe by another Den hub on this computer. Stop that one, then turn this on again.'
          : "The hub couldn't open port $port on this device. Check its firewall, then turn this on again.";
    } on Object catch (e) {
      _state = LocalHubState.failed;
      _error = "The hub couldn't start (${e.runtimeType}). Turn this off and on again, or restart Den.";
    }
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _tick?.cancel();
    _tick = null;
    final hub = _hub;
    _hub = null;
    _connected = 0;
    _addresses = const [];
    _state = LocalHubState.off;
    _error = null;
    notifyListeners();
    await hub?.stop();
  }

  static Future<String?> _defaultDataDir() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return '${dir.path}${Platform.pathSeparator}hub';
    } on Object {
      return null;
    }
  }

  static Future<List<Uri>> _lanAddresses(int port) async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      return [
        for (final i in interfaces)
          for (final a in i.addresses)
            if (_private(a.rawAddress)) Uri(scheme: 'http', host: a.address, port: port),
      ];
    } on Object {
      return const [];
    }
  }

  static bool _private(List<int> b) =>
      b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168);
}
