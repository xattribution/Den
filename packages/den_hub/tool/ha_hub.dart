// Starts a hub over the demo family on a free port for the Home Assistant contract check, prints
// `{"url": ..., "token": ...}` on one line, and stops when standard input closes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';

Future<void> main() async {
  final phone = await createDemoFamily();
  final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
  await den.requestJoin(
    familyId: phone.familyId!,
    founderPubkey: phone.founderPubkey!,
    deviceName: 'Contract hub',
    kind: DeviceKind.hub,
    mode: DeviceMode.hub,
  );
  await phone.ingest(den.changesSince(const {}));
  await phone.approveDevice(den.deviceId, mode: DeviceMode.hub);
  final token = await phone.addTokenConnection(label: 'Home Assistant', scopes: {...Scope.values});
  await den.ingest(phone.changesSince(const {}));
  final hub = await DenHub.start(den, HubConfig(
    port: 0,
    host: InternetAddress.loopbackIPv4,
    mdns: false,
    log: HubLog(level: LogLevel.warn, sink: stderr.writeln),
  ));
  stdout.writeln(jsonEncode({'url': 'http://127.0.0.1:${hub.port}', 'token': token, 'device': den.deviceId}));
  await stdout.flush();
  await stdin.drain<void>();
  await hub.stop();
  await den.close();
  await phone.close();
  exit(0);
}
