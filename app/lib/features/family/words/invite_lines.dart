import 'package:den_core/den_core.dart';

import '../../../app/family_reads.dart';
import '../../calendar/calendar_words.dart';
import 'family_words.dart';

/// How a device an invite let in by itself is told, the same in Needs you, History and on the
/// person's page: "Dad joined on an iPhone", "With your invite, Oct 28".
abstract final class InviteLines {
  /// "an iPhone" from "Dad's iPhone", or the device's own name when it isn't named that way.
  static String _what(Device d, String? owner) {
    final name = d.name;
    final prefix = owner == null ? null : '${FamilyWords.possessive(owner)} ';
    if (prefix != null && name.startsWith(prefix) && name.length > prefix.length) {
      final word = name.substring(prefix.length);
      return '${RegExp(r'^[aeiouAEIOU]|^i[A-Z]').hasMatch(word) ? 'an' : 'a'} $word';
    }
    return name;
  }

  /// "Dad joined on an iPhone"; "Kitchen display joined the family" for a shared screen.
  static String sentence(FamilyReads app, Device d) {
    final proof = inviteOf(d);
    final owner = proof?.member == null ? null : app.memberById(proof!.member)?.name;
    if (owner == null) return '${d.name} joined the family';
    return '$owner joined on ${_what(d, owner)}';
  }

  /// Whose invite it was and when: "With your invite, today", "With Sam's invite, Oct 28".
  static String detail(FamilyReads app, Device d) {
    final proof = inviteOf(d);
    final made = proof == null ? null : app.den.inviteKey(proof.invite);
    final by = made?.by;
    final whose = by == null ? 'an' : (by == app.me?.id ? 'your' : FamilyWords.possessive(app.memberById(by)?.name ?? 'a parent'));
    final day = app.formats.localDate(d.rec.created.millis);
    final at = switch (app.formats.relative(day, app.today)) {
      'Today' => 'today',
      'Yesterday' => 'yesterday',
      _ => app.formats.monthDay(day, relativeTo: app.today),
    };
    return 'With $whose invite, $at';
  }

  /// "That wasn't Dad", or "We didn't add it" for a device that is nobody's own.
  static String notThem(FamilyReads app, Device d) {
    final member = inviteOf(d)?.member;
    final owner = member == null ? null : app.memberById(member)?.name;
    return owner == null ? "We didn't add it" : "That wasn't $owner";
  }

  /// What That wasn't Dad did: "We removed Dad's iPhone. Dad needs a new invite."
  static String disowned(FamilyReads app, Device d, DisownedInvite done) {
    final owner = done.member == null ? null : app.memberById(done.member!)?.name;
    return owner == null ? 'We removed ${d.name}' : 'We removed ${d.name}. $owner needs a new invite.';
  }

  /// In History: "joined with Alex's invite".
  static String howJoined(FamilyReads app, Map<Object?, Object?> proof) {
    final made = proof['invite'] is String ? app.den.inviteKey(proof['invite'] as String) : null;
    final by = made == null ? null : app.memberById(made.by)?.name;
    return by == null ? 'an invite' : "${FamilyWords.possessive(by)} invite";
  }
}
