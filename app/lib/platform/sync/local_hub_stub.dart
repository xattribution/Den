import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';

import 'hub_keep_alive.dart';
import 'local_hub.dart';

/// Browsers and other platforms without `dart:io` can't run a hub.
const bool localHubSupported = false;

LocalHub createLocalHub({int port = 47733, bool mdns = true, String? dataDir, String name = 'hub', HubKeepAlive? keepAlive}) =>
    _NoHub();

Future<void> forgetLocalHub(String name) async {}

class _NoHub extends LocalHub {
  @override
  LocalHubState get state => LocalHubState.off;

  @override
  String? get error => null;

  @override
  List<Uri> get addresses => const [];

  @override
  int get connected => 0;

  @override
  SyncNode? get node => null;

  @override
  Future<void> start(Den den, {Uri? relay}) async {}

  @override
  Future<void> stop() async {}
}
