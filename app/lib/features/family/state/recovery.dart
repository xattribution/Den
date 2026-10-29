import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show RecoveryWords;

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

  /// The key Needs you puts a recovery away under on this device (`AppState.markSeen`): every
  /// other parent's own device says once that a phone got in, until someone there says so.
  static String noticeKey(Device d) => 'recovered:${d.id}';

  /// Phones recovery let in that this device hasn't put away yet, this one aside.
  static List<Device> unseen(Den den, bool Function(String key) seen) => [
        for (final d in letIn(den))
          if (d.id != den.deviceId && !seen(noticeKey(d))) d,
      ];
}
