import 'dart:async';
import 'dart:io';

import 'package:den_net/den_net.dart';
import 'package:den_net/io.dart' as io;

import 'hub_client.dart';

/// Hubs of this family answering mDNS on the home network.
Future<List<Uri>> discoverHubs(String familyId) async {
  try {
    final found = await io.discoverHubs(timeout: const Duration(seconds: 2));
    return [
      for (final hub in found)
        if (hub.familyId == null || hub.familyId == familyId) hub.syncUri,
    ];
  } on Object {
    return const [];
  }
}

/// Every hub answering mDNS on the home network, in this family or waiting for setup.
Future<List<FoundHub>> findHubsNearby() async {
  try {
    final found = await io.discoverHubs(timeout: const Duration(seconds: 3));
    return [
      for (final hub in found)
        FoundHub(
          name: hub.txt['name'] ?? hub.instance.split('.').first,
          base: Uri(scheme: 'http', host: hub.addresses.isEmpty ? hub.host : hub.addresses.first.address, port: hub.port),
          deviceId: hub.deviceId,
          familyId: hub.familyId,
        ),
    ];
  } on Object {
    return const [];
  }
}

HttpServer? _server;
Timer? _closeTimer;

/// Lets another device on the same Wi-Fi reach this one directly for the next 15 minutes, for
/// pairing when the family has no hub and no relay. Returns the address to put in the invite.
Future<Uri?> serveTemporarily(SyncNode node) async {
  final address = await _lanAddress();
  if (address == null) return null;
  _closeTimer?.cancel();
  _server ??= await io.serveSync(node, port: 0);
  _closeTimer = Timer(const Duration(minutes: 15), () {
    unawaited(_server?.close(force: true));
    _server = null;
  });
  return Uri(scheme: 'ws', host: address.address, port: _server!.port, path: '/ws');
}

Future<InternetAddress?> _lanAddress() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      final b = address.rawAddress;
      final private = b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168);
      if (private) return address;
    }
  }
  return null;
}
