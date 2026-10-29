import 'package:den_core/den_core.dart';

import '../../../app/family_reads.dart';
import '../../calendar/calendar_words.dart';
import 'family_words.dart';

/// How a device let in by recovery is told, the same in History, Needs you and on the person's
/// page: "Alex's new iPhone was let in with Alex's recovery words", "... by the hub's recovery".
abstract final class RecoveryLines {
  /// "with Alex's recovery words" or "by the hub's recovery".
  static String how(FamilyReads app, RecoveryProof proof) {
    final name = app.memberById(proof.member)?.name;
    return switch (proof.kind) {
      RecoveryKind.words => name == null ? 'with recovery words' : 'with ${FamilyWords.possessive(name)} recovery words',
      RecoveryKind.hub => "by the hub's recovery",
    };
  }

  /// "Alex's new iPhone was let in with Alex's recovery words".
  static String sentence(FamilyReads app, Device d) {
    final proof = recoveryOf(d);
    if (proof == null) return '${d.name} joined the family';
    return '${d.name} was let in ${how(app, proof)}';
  }

  /// When it was let in: "Oct 28".
  static String when(FamilyReads app, Device d) {
    final at = d.rec.fieldTimes['recovery']?.millis ?? d.rec.created.millis;
    return app.formats.monthDay(app.formats.localDate(at), relativeTo: app.today);
  }

  /// The line Needs you shows under it.
  static String detail(FamilyReads app, Device d) {
    final proof = recoveryOf(d);
    final name = proof == null ? null : app.memberById(proof.member)?.name;
    return switch (proof?.kind) {
      RecoveryKind.hub => '${when(app, d)}. Whoever runs your hub let it in for ${name ?? 'a parent'}',
      _ => '${when(app, d)}. If ${name ?? 'they'} didn\'t, remove it',
    };
  }
}
