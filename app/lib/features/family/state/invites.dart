import 'package:den_core/den_core.dart';

/// Devices an invite let in by itself (den_core's invite_keys.dart): the invite carried a key a
/// parent's own phone made, so nobody tapped Approve. Every parent's own device says so in Needs
/// you ("Dad joined on an iPhone"), with Got it and That wasn't Dad, so nobody gets in unseen.
abstract final class Invites {
  /// How long a device an invite let in is said in Needs you, unless someone puts it away first.
  static const Duration told = Duration(days: 14);

  /// Devices in the family that an invite let in, newest first.
  static List<Device> letIn(Den den) => [
        for (final d in den.devices)
          if (d.approved && !d.revoked && inviteOf(d) != null) d,
      ]..sort((a, b) => b.rec.created.compareTo(a.rec.created));

  /// The key Needs you puts one away under on this device (`AppState.markSeen`).
  static String noticeKey(Device d) => 'invited:${d.id}';

  /// The ones this device hasn't put away, from the last [told], leaving out this device itself
  /// and the person's own other devices (they know).
  static List<Device> unseen(Den den, bool Function(String key) seen, {required int now, String? me}) => [
        for (final d in letIn(den))
          if (d.id != den.deviceId &&
              (me == null || inviteOf(d)?.member != me) &&
              d.rec.created.millis > now - told.inMilliseconds &&
              !seen(noticeKey(d)))
            d,
      ];
}
