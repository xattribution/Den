import 'package:flutter/material.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'app.dart';
import 'boot/boot.dart';
import 'net/den_network.dart';
import 'net/net_pairing.dart';
import 'net/pairing.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  final den = await Boot.start();
  final network = await DenNetwork.load(den);
  Pairing.service = NetPairing(network);
  await network.start();
  runApp(DenApp(state: await AppState.load(den, network: network)));
}
