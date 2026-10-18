import 'dart:async';

import 'package:flutter/material.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'app.dart';
import 'capture/capture_service.dart';
import 'capture/capture_settings.dart';
import 'capture/hub_link.dart';
import 'capture/platform_capture.dart';
import 'boot/boot.dart';
import 'boot/boot_screen.dart';
import 'net/den_network.dart';
import 'net/net_pairing.dart';
import 'net/pairing.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BootScreen());
  tzdata.initializeTimeZones();
  final den = await Boot.start();
  final network = await DenNetwork.load(den);
  Pairing.service = NetPairing(network);
  Capture.service = CaptureService(settings: await CaptureSettings.load(), hubClient: hubCaptureClient(network));
  runApp(DenApp(state: await AppState.load(den, network: network)));
  unawaited(network.start());
  // Shares that opened Den, that arrive while it's open, and that waited while it was away.
  unawaited(Capture.collectShares());
  const PlatformCapture().sharesArrived.listen((_) => Capture.collectShares());
  AppLifecycleListener(onResume: Capture.collectShares);
}
