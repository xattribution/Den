import 'package:den_net/den_net.dart';

import 'hub_client.dart';

/// Browsers can't use mDNS or listen for connections; they reach the hub that served them.
Future<List<Uri>> discoverHubs(String familyId) async => const [];

/// Browsers can't host a pairing; they always join through the hub or the relay.
Future<Uri?> serveTemporarily(SyncNode node) async => null;

/// Browsers can't use mDNS; the hub that served the page is the one they know.
Future<List<FoundHub>> findHubsNearby() async => const [];
