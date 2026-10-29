import 'package:den_core/den_core.dart';

import '../../../app/family_reads.dart';
import '../../advanced/advanced.dart' show bookkeeping, fieldLabel, historyLine, valueWords;
import '../../calendar/calendar_words.dart' show joinWords;

/// One change the helper made, as its row says it: "Moved Dentist to 4:00 PM Tue", "Added Milk
/// and Eggs to Groceries", "Removed Feed the cat". Read from the History entries of the
/// receipt's changes, the way History tells them; [fallback] (the action's own line) when there
/// are none to read.
String changeWords(FamilyReads app, List<String> changes, {required String fallback}) {
  final entries = app.den.historyOf(changes);
  final noise = bookkeeping(entries);
  final shown = [
    for (final e in entries)
      if (!noise.contains(e)) e,
  ];
  if (shown.isEmpty) return cleanSummary(fallback);

  final first = shown.first;
  final sameKind = shown.every((e) => e.type == first.type && e.verb == first.verb);
  if (sameKind && first.type == RecordType.item && first.verb == 'added') {
    final lists = {for (final e in shown) _listOf(app, e)};
    final titles = [for (final e in shown) e.title];
    return lists.length == 1 && lists.single != null
        ? 'Added ${joinWords(titles)} to ${lists.single}'
        : 'Added ${joinWords(titles)}';
  }
  if (sameKind && shown.length > 1) return '${_verb(first.verb)} ${joinWords([for (final e in shown) e.title])}';
  final one = _one(app, first);
  return shown.length == 1 ? one : '$one, and ${shown.length - 1} more';
}

/// The action's own line without its ids and the period: "Added Dentist, Tue, Oct 20".
String cleanSummary(String text) {
  final line = text.split('\n').first.replaceAll(RegExp(r'\s*\[[^\]]*\]'), '').trim();
  return line.endsWith('.') ? line.substring(0, line.length - 1) : line;
}

String? _listOf(FamilyReads app, HistoryEntry e) {
  for (final d in e.diffs) {
    if (d.field == 'list' && d.after is String) return app.den.list(d.after! as String)?.list.title;
  }
  for (final l in app.den.lists) {
    if (l.items.any((i) => i.id == e.rid)) return l.list.title;
  }
  return null;
}

String _verb(String verb) => switch (verb) {
  'checked' || 'completed' => 'Checked off',
  'unchecked' || 'reopened' => 'Unchecked',
  'requested' => 'Asked for',
  'restored' || 'brought back' => 'Put back',
  _ => verb.isEmpty ? 'Changed' : '${verb[0].toUpperCase()}${verb.substring(1)}',
};

String _one(FamilyReads app, HistoryEntry e) {
  final f = app.formats;
  final line = historyLine(app, e);
  if (e.type == RecordType.adjustment && (e.verb == 'gave' || e.verb == 'took')) {
    // History says points; the family says stars.
    return '${_verb(e.verb)} ${line.title.replaceAll(RegExp(r'\bpoints?\b'), 'stars').replaceAll('1 stars', '1 star')}';
  }
  if (e.type == RecordType.item && e.verb == 'added') {
    final list = _listOf(app, e);
    return list == null ? 'Added ${e.title}' : 'Added ${e.title} to $list';
  }
  if (e.type == RecordType.event || e.type == RecordType.eventException) {
    FieldDiff? start;
    for (final d in line.diffs) {
      if (d.field == 'start') start = d;
    }
    final moved = start?.after;
    if (line.verb == 'changed' && moved is num) {
      final ms = moved.toInt();
      return 'Moved ${e.title} to ${f.time(ms)} ${f.weekday(f.localDate(ms))}';
    }
  }
  if (line.verb == 'changed' && line.diffs.length == 1) {
    final d = line.diffs.single;
    final after = valueWords(app, e.type, d.field, d.after);
    if ((d.field == 'title' || d.field == 'text') && after != null) {
      return 'Renamed ${valueWords(app, e.type, d.field, d.before) ?? line.title} to $after';
    }
    if (after != null) return '${line.title}: ${fieldLabel(d.field).toLowerCase()} is now $after';
  }
  return '${_verb(line.verb)} ${line.title}';
}
