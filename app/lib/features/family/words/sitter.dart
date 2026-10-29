/// A sitter's last day, as a parent and the sitter read it. Plain Dart, so the hub and an
/// assistant can say it the same way.
library;

import 'package:den_core/den_core.dart';
import 'package:intl/intl.dart';

import '../../../app/format.dart';

/// A day near [today] by name ("Sunday", "today", "tomorrow"), else "Sun, Oct 18". With
/// [relative], yesterday is "yesterday" too.
String dayWords(Formats f, String date, String today, {bool relative = true}) {
  if (date == today) return 'today';
  if (date == f.addDays(today, 1)) return 'tomorrow';
  if (relative && date == f.addDays(today, -1)) return 'yesterday';
  final days = f.dateTime(date).difference(f.dateTime(today)).inHours.abs() / 24;
  return days < 7 ? DateFormat('EEEE').format(f.dateTime(date)) : f.short(date);
}

/// The coming Sunday: today when it is Sunday.
String comingSunday(Formats f, String today) {
  final weekday = f.dateTime(today).weekday % 7; // Sunday 0
  return f.addDays(today, weekday == 0 ? 0 : 7 - weekday);
}

/// What a sitter's page says about their access: "Until Sunday", "Ended yesterday", "No end".
String untilWords(Member m, Formats f, String today) {
  final until = m.until;
  if (until == null) return 'No end';
  if (m.accessEndedOn(today)) return 'Ended ${dayWords(f, until, today)}';
  return 'Until ${dayWords(f, until, today)}';
}

/// "Sam's access ended Sunday": what Needs you and History say once a sitter's last day has
/// passed.
String accessEndedWords(String name, String until, Formats f, String today) =>
    "$name's access ended ${dayWords(f, until, today, relative: false)}";

/// What choosing [until] for [name] does, said before it saves.
String untilChange(String name, String? until, Formats f, String today, {bool removed = false}) {
  final again = removed ? " $name's old devices stay removed, so invite $name again after you save." : '';
  if (until == null) return '$name can use Den until you remove $name.$again';
  return '$name can use Den through ${f.long(until)}. After that, $name\'s devices stop syncing, and the next time '
      'you open Den they\'re removed.$again';
}
