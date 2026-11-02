import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';
import 'recovery.dart';

/// "Save your recovery words", on each parent's own device, until that parent has saved theirs
/// or the family has two parents with an approved device of their own: then either one can let
/// the other back in. Without it a family whose only parent device is a Home Screen web app that
/// gets wiped could never approve anything again. It can't be put away for good: "Remind me
/// later" hides it from Needs you for [later], and Settings → Family shows it all along.
abstract final class RecoveryReminder {
  static const String title = 'Save your recovery words';
  static const String detail = "If this phone is lost, they're the only way back in.";

  /// How long "Remind me later" hides it from Needs you.
  static const Duration later = Duration(days: 3);

  /// What "Remind me later" is kept under on this device ([AppState.snooze]).
  static String snoozeKey(String member) => 'recovery-words:$member';

  /// Whether to ask whoever uses [app]'s device. With [now], not while they put it off; without,
  /// whether the words are missing at all (Settings).
  static bool due(AppState app, {int? now}) {
    final me = app.me;
    if (me == null || !me.isParent || !app.allowsTrust(DenAction.manageFamily)) return false;
    if (Recovery.hasWords(me) || parentsWithOwnDevice(app.den) >= 2) return false;
    final until = now == null ? null : app.snoozedUntil(snoozeKey(me.id));
    return until == null || now! >= until;
  }

  /// How many parents have an approved personal device in the family.
  static int parentsWithOwnDevice(Den den) {
    final parents = {for (final m in den.members) if (m.isParent) m.id};
    return {
      for (final d in den.devices)
        if (d.mode == DeviceMode.personal && d.approved && !d.revoked && parents.contains(d.member)) d.member,
    }.length;
  }
}
