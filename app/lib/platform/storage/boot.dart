import 'dart:convert';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import 'device_keychain.dart';
import 'memberships.dart';
import 'storage_stub.dart'
    if (dart.library.io) 'storage_native.dart'
    if (dart.library.js_interop) 'storage_web.dart';
import '../capabilities.dart';

/// Where this device's keys are kept.
abstract interface class KeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Starts the engine: this device's keys from the platform keychain (created on first run),
/// its change log from local storage, and, with `--dart-define=DEN_DEMO=true`, a demo family.
///
/// A device holds one engine per family ([Membership]): the first under the names Den always
/// used ([start]), each other one under its own ([startLog]), with keys of its own.
class Boot {
  static const keysName = Membership.primaryKeys;
  static const demo = bool.fromEnvironment('DEN_DEMO');

  /// With [background] (a refresh with Den closed, maybe on a locked phone) the engine opens
  /// only as the device it already is; it never starts over.
  static Future<Den> start({bool background = false}) async =>
      open(storage: await openDeviceStorage(), keys: await _keyStore(), background: background);

  /// The engine of [log]: its own change log and its own keys. The first log is [start]'s.
  static Future<Den> startLog(Membership log, {bool background = false}) async => open(
        storage: await openDeviceStorage(name: log.storage),
        keys: await _keyStore(),
        keysName: log.keys,
        background: background,
        allowDemo: log.primary,
      );

  /// A fresh engine for a family this device is about to join: an empty log under [log]'s
  /// name and new keys of its own. Whatever an earlier try left there is cleared first.
  static Future<Den> startFresh(Membership log) async {
    await forgetLog(log);
    return startLog(log);
  }

  /// Deletes what this device kept for [log]: its change log and its keys. The engine over it
  /// must be closed first. Names another listed family is kept under (compared as a file
  /// system that ignores case would) are never deleted.
  static Future<void> forgetLog(Membership log) async {
    final listed = await Memberships.load();
    final shared = listed.any((o) => !(o.id == log.id && o.slot == log.slot && o.primary == log.primary) && o.sharesStorageWith(log));
    if (shared) {
      debugPrint('Den kept ${log.storage}: another family on this device is kept under that name.');
      return;
    }
    await deleteDeviceStorage(log.storage);
    try {
      await (await _keyStore()).delete(log.keys);
    } on Object {
      // A keychain item that can't be deleted has no log left to sign for: the next engine
      // under this name finds no family and starts over with new keys.
    }
  }

  /// Opens the engine over [storage] with this device's keys from [keys].
  ///
  /// A device's keys and its log belong together. Keys whose log is gone (a browser that
  /// cleared or evicted its storage while the keychain kept them, a phone restored without its
  /// files) may already be approved, or turned away, by the family, and reusing them would
  /// restart the change counter under ids peers already hold. A log whose keys are gone was
  /// signed by an identity this device no longer has. Either way the device starts over with
  /// fresh keys and an empty log, and joins the family again. So does a device that left its
  /// family, since the family remembers the keys it declined or removed. With [background] it
  /// throws instead, so a keychain that can't be read yet never costs the device its family.
  ///
  /// [keysName] is the keychain item of the log's keys ([Membership.keys]).
  static Future<Den> open({
    required DenStorage storage,
    required KeyStore keys,
    String keysName = Boot.keysName,
    bool background = false,
    bool allowDemo = true,
  }) async {
    final meta = await storage.loadMeta();
    final inFamily = meta?['familyId'] is String;
    final saved = await keys.read(keysName);
    DeviceKeys? deviceKeys;
    if (saved != null && inFamily) {
      try {
        deviceKeys = await DeviceKeys.fromJson(Map<String, Object?>.from(jsonDecode(saved) as Map));
      } on Object {
        deviceKeys = null;
      }
    }
    if (deviceKeys == null) {
      if (background) throw StateError("This device's keys and log don't belong together; open Den to start over");
      if (meta != null || (await storage.loadChanges()).isNotEmpty) await storage.clear();
      deviceKeys = await DeviceKeys.generate();
      await keys.write(keysName, jsonEncode(await deviceKeys.toJson()));
    }
    if (demo && allowDemo && !inFamily) return createDemoFamily(storage: storage, keys: deviceKeys);
    return Den.open(storage: storage, keys: deviceKeys);
  }

  /// The platform keychain. A browser page that isn't a secure context (a hub opened by its
  /// plain `http://` address on the home network) has no Web Crypto, which the browser's
  /// keychain needs, so there the keys stay in the page's own storage.
  static Future<KeyStore> _keyStore() async {
    const keychain = _Keychain();
    if (!Capabilities.web) return keychain;
    try {
      await keychain.read(keysName);
      return keychain;
    } on Object {
      return _PageStorage();
    }
  }
}

class _Keychain implements KeyStore {
  const _Keychain();

  @override
  Future<String?> read(String key) => const DeviceKeychain().read(key);

  @override
  Future<void> write(String key, String value) => const DeviceKeychain().write(key, value);

  @override
  Future<void> delete(String key) => const DeviceKeychain().delete(key);
}

class _PageStorage implements KeyStore {
  @override
  Future<String?> read(String key) async => (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String key, String value) async {
    await (await SharedPreferences.getInstance()).setString(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await (await SharedPreferences.getInstance()).remove(key);
  }
}
