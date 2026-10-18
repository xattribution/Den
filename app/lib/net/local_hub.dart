import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:flutter/foundation.dart';

import 'hub_keep_alive.dart';
import 'local_hub_stub.dart' if (dart.library.io) 'local_hub_io.dart' as impl;

enum LocalHubState { off, starting, running, failed }

/// The family's hub running inside this app ("Keep the family online"), on desktops and Android.
/// den_hub needs `dart:io`, so it is only ever imported behind the conditional import above;
/// browsers and iOS get [supported] false.
abstract class LocalHub extends ChangeNotifier {
  /// [port] 0 picks a free one and [dataDir] null uses the app's support directory, for tests.
  /// [keepAlive] defaults to the platform's ([HubKeepAlive.platform]): on Android, the
  /// foreground service that keeps the hub running while the app is in the background.
  static LocalHub create({int port = 47733, bool mdns = true, String? dataDir, HubKeepAlive? keepAlive}) =>
      impl.createLocalHub(port: port, mdns: mdns, dataDir: dataDir, keepAlive: keepAlive);

  /// Whether this platform can run the hub in-process.
  static bool get supported => impl.localHubSupported;

  LocalHubState get state;

  /// Why the hub couldn't start, for people ("Port 47733 is in use by another program...").
  String? get error;

  /// Where other devices reach this hub on the home network: `http://192.168.1.20:47733`.
  List<Uri> get addresses;

  /// Devices connected to the hub right now.
  int get connected;

  /// The hub's sync node while it runs; pairing goes through it so its invites are accepted.
  SyncNode? get node;

  Future<void> start(Den den, {Uri? relay});

  Future<void> stop();
}
