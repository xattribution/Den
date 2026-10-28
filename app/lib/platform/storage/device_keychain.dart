import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// This device's keychain, set up so a background refresh can read it while the phone is
/// locked: on iPhone and Mac, items are readable after the first unlock since the device
/// started, and never leave this device (no iCloud Keychain, no backup restore onto another
/// phone, since the keys are this device's identity in the family).
///
/// On the Mac the file-based keychain is used, which needs no Keychain Sharing entitlement.
class DeviceKeychain {
  const DeviceKeychain();

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      usesDataProtectionKeychain: false,
    ),
  );

  /// Where earlier versions wrote: readable only while unlocked.
  static const _earlier = FlutterSecureStorage();

  /// Reads [key], moving an item an earlier version wrote over to the current settings.
  Future<String?> read(String key) async {
    final value = await _storage.read(key: key);
    if (value != null) return value;
    final String? old;
    try {
      old = await _earlier.read(key: key);
    } on Object {
      return null;
    }
    if (old == null) return null;
    try {
      await _earlier.delete(key: key);
      await _storage.write(key: key, value: old);
    } on Object {
      // Still readable where it was; try moving it again next time.
    }
    return old;
  }

  Future<void> write(String key, String value) async {
    try {
      await _earlier.delete(key: key);
    } on Object {
      // Nothing there.
    }
    await _storage.write(key: key, value: value);
  }

  Future<void> delete(String key) async {
    await _storage.delete(key: key);
    try {
      await _earlier.delete(key: key);
    } on Object {
      // Nothing there.
    }
  }
}
