import 'dart:convert';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';

import 'device_keychain.dart';
import 'storage_stub.dart'
    if (dart.library.io) 'storage_native.dart'
    if (dart.library.js_interop) 'storage_web.dart';

/// Starts the engine: this device's keys from the platform keychain (created on first run),
/// its change log from local storage, and, with `--dart-define=DEN_DEMO=true`, a demo family.
class Boot {
  static const _keysName = 'den.device.keys';
  static const demo = bool.fromEnvironment('DEN_DEMO');

  static Future<Den> start() async {
    final keys = await _loadKeys();
    final storage = await openDeviceStorage();
    if (demo) {
      final existing = await storage.loadMeta();
      if (existing == null) return createDemoFamily(storage: storage, keys: keys);
    }
    return Den.open(storage: storage, keys: keys);
  }

  static Future<DeviceKeys> _loadKeys() async {
    const keychain = DeviceKeychain();
    final saved = await keychain.read(_keysName);
    if (saved != null) {
      return DeviceKeys.fromJson(Map<String, Object?>.from(jsonDecode(saved) as Map));
    }
    final keys = await DeviceKeys.generate();
    await keychain.write(_keysName, jsonEncode(await keys.toJson()));
    return keys;
  }
}
