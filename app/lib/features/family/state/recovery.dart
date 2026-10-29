import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show RecoveryWords;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A parent's recovery words: the 12 words that let a new phone in as them when theirs is lost
/// and no other parent's device is left to (den_core's recovery.dart). Only the parent keeps the
/// words; the family keeps the public half of the key they stretch to, written on the parent's
/// own device through `TrustActions.setRecoveryKey`.
abstract final class Recovery {
  /// Twelve new words.
  static List<String> newWords() => RecoveryWords.generate();

  /// The public half of the key [words] stretch to. Stretching takes a moment, by design.
  static Future<String> publicKey(List<String> words) async => (await RecoveryWords.key(words)).publicKey;

  /// Whether [m] has recovery words set up.
  static bool hasWords(Member m) => recoveryKeyOf(m) != null;

  /// Devices in the family that recovery let in, newest first.
  static List<Device> letIn(Den den) => [
        for (final d in den.devices)
          if (d.approved && !d.revoked && recoveryOf(d) != null) d,
      ]..sort((a, b) => b.rec.created.compareTo(a.rec.created));

  /// When this device was let in by recovery, or null when it joined another way.
  static RecoveryProof? ofThisDevice(Den den) {
    final d = den.thisDevice;
    return d == null ? null : recoveryOf(d);
  }

  /// [member]'s other own devices still in the family: after a recovery, the phone that was lost.
  static List<Device> otherDevices(Den den, String member) => [
        for (final d in den.devices)
          if (d.member == member && d.id != den.deviceId && d.mode == DeviceMode.personal && d.approved && !d.revoked) d,
      ];
}

/// Which recoveries this device has already shown in Needs you, kept on the device: every
/// device says once that a parent's new phone was let in, until someone here says OK.
abstract final class RecoveryNotices {
  static const _key = 'den.recovery.seen';

  /// Device ids already acknowledged here.
  static final ValueNotifier<Set<String>> seen = ValueNotifier(const {});

  static bool _loaded = false;

  /// Reads what this device acknowledged before; once.
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      seen.value = {...seen.value, ...?prefs.getStringList(_key)};
    } on Object {
      // No storage (a test, a private window): the notice shows until OK on this run.
    }
  }

  /// Remembers that someone here saw [device]'s recovery.
  static Future<void> acknowledge(String device) async {
    seen.value = {...seen.value, device};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, seen.value.toList()..sort());
    } on Object {
      // Kept for this run.
    }
  }
}
