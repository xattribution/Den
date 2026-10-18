import 'package:den_core/den_core.dart';
import 'package:den_core/time.dart';

import 'context.dart';
import 'draft.dart';
import 'lexicon.dart';

const int _maxTitle = 200;
const int _maxEntries = 60;
const _dayCodes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

/// Turns what a reader returned ([CaptureWire]'s shape, leniently: models get types and formats
/// wrong) into a draft for this family: names matched to members, items to lists, repeats to
/// RRULEs, local dates checked. Anything someone should look at becomes an issue on its entry;
/// what can't be read at all is dropped.
CaptureDraft draftFrom(Map<String, Object?> wire, CaptureContext context, {required CaptureOrigin origin}) {
  final r = _Resolver(context);
  final entries = <DraftEntry>[
    for (final (i, raw) in _maps(wire['events']).indexed) ?r.event('e$i', raw),
    for (final (i, raw) in _maps(wire['chores']).indexed) ...r.chores('c$i', raw),
    for (final (i, raw) in _maps(wire['items']).indexed) ?r.item('i$i', raw),
    for (final (i, raw) in _maps(wire['reminders']).indexed) ?r.reminder('r$i', raw),
  ];
  return CaptureDraft(
    origin: origin,
    entries: entries.take(_maxEntries).toList(),
    unclear: [for (final u in _list(wire['unclear']).take(5)) ?_str(u, max: 300)],
  );
}

/// An RRULE for a [CaptureWire] repeat starting on [date], and the first date it really falls
/// on ("every Saturday" starting on a Thursday starts that Saturday). Null when it can't be read.
(String, String)? ruleFor(Map<String, Object?> repeat, String date) {
  final freq = switch (_str(repeat['every'])?.toLowerCase()) {
    'day' || 'daily' => 'DAILY',
    'week' || 'weekly' => 'WEEKLY',
    'month' || 'monthly' => 'MONTHLY',
    'year' || 'yearly' => 'YEARLY',
    _ => null,
  };
  if (freq == null) return null;
  final interval = _int(repeat['interval']) ?? 1;
  String? code(Object? d) {
    if (d is! String || d.trim().length < 2) return null;
    final c = d.trim().substring(0, 2).toUpperCase();
    return _dayCodes.contains(c) ? c : null;
  }

  final days = {for (final d in _list(repeat['days'])) ?code(d)}.toList()
    ..sort((a, b) => _dayCodes.indexOf(a).compareTo(_dayCodes.indexOf(b)));
  final nth = _int(repeat['nth']);
  final monthDay = _int(repeat['monthDay']);
  final until = _date(repeat['until']);
  final count = _int(repeat['count']);

  var start = date;
  final parts = ['FREQ=$freq'];
  if (interval > 1 && interval <= 1000) parts.add('INTERVAL=$interval');
  if (freq == 'WEEKLY') {
    final byDay = days.isEmpty ? [_dayCodes[weekdayOf(date) - 1]] : days;
    parts.add('BYDAY=${byDay.join(',')}');
    for (var i = 0; i < 7; i++) {
      final d = addDays(date, i);
      if (byDay.contains(_dayCodes[weekdayOf(d) - 1])) {
        start = d;
        break;
      }
    }
  } else if (freq == 'DAILY' && days.isNotEmpty && days.length < 7) {
    // "Every weekday" said as a daily repeat on some days.
    parts
      ..[0] = 'FREQ=WEEKLY'
      ..add('BYDAY=${days.join(',')}');
    for (var i = 0; i < 7; i++) {
      final d = addDays(date, i);
      if (days.contains(_dayCodes[weekdayOf(d) - 1])) {
        start = d;
        break;
      }
    }
  } else if (freq == 'MONTHLY' && nth != null && nth != 0 && nth.abs() <= 5 && days.length == 1) {
    parts.add('BYDAY=$nth${days.single}');
    start = _nthWeekday(date, nth, _dayCodes.indexOf(days.single) + 1) ?? date;
  } else if (freq == 'MONTHLY' && monthDay != null && monthDay != 0 && monthDay.abs() <= 31) {
    parts.add('BYMONTHDAY=$monthDay');
  }
  if (until != null && until.compareTo(start) >= 0) {
    parts.add('UNTIL=${until.replaceAll('-', '')}');
  } else if (count != null && count > 0 && count <= 1000) {
    parts.add('COUNT=$count');
  }
  final rule = parts.join(';');
  if (!RecurrenceRule.isValid(rule)) return null;
  return (RecurrenceRule.parse(rule).toString(), start);
}

/// The [nth] (negative: from the end) [weekday] (1 Monday) of [date]'s month, or of the next
/// month when that one has passed.
String? _nthWeekday(String date, int nth, int weekday) {
  for (var months = 0; months < 2; months++) {
    final base = DateTime.utc(int.parse(date.substring(0, 4)), int.parse(date.substring(5, 7)) + months, 1);
    final days = <DateTime>[
      for (var d = base; d.month == base.month; d = d.add(const Duration(days: 1)))
        if (d.weekday == weekday) d,
    ];
    final i = nth > 0 ? nth - 1 : days.length + nth;
    if (i < 0 || i >= days.length) continue;
    final d = days[i];
    final text = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    if (text.compareTo(date) >= 0) return text;
  }
  return null;
}

class _Resolver {
  _Resolver(this.c);
  final CaptureContext c;

  /// A date, or "today" and "tomorrow" as small models sometimes leave them.
  String? day(Object? raw) => switch (raw is String ? raw.trim().toLowerCase() : null) {
        'today' || 'tonight' => c.today,
        'tomorrow' => addDays(c.today, 1),
        _ => _date(raw),
      };

  (List<String>, List<DraftIssue>) people(Object? raw) {
    final ids = <String>[];
    final issues = <DraftIssue>[];
    for (final name in _list(raw)) {
      final n = _str(name, max: 100);
      if (n == null) continue;
      if (const {'everyone', 'everybody', 'family', 'all', 'the family', 'whole family'}.contains(n.toLowerCase())) continue;
      final p = c.person(n);
      if (p == null) {
        issues.add(DraftIssue(IssueKind.unknownPerson, 'No one in the family is called $n'));
      } else if (!ids.contains(p.id)) {
        ids.add(p.id);
      }
    }
    return (ids, issues);
  }

  DraftEvent? event(String key, Map<String, Object?> raw) {
    final title = _title(raw['title']);
    if (title == null) return null;
    final issues = <DraftIssue>[];
    var date = day(raw['date']);
    if (date == null) {
      issues.add(const DraftIssue(IssueKind.needsDay, 'Den couldn\'t tell which day'));
      date = c.today;
    }
    var start = _time(raw['start']);
    var end = start == null ? null : _time(raw['end']);
    var endDate = day(raw['endDate']);
    if (endDate != null && endDate.compareTo(date) <= 0) endDate = null;
    if (start != null && end != null && endDate == null && minutesOf(end) <= minutesOf(start)) {
      // "11 to 1" read as 11:00 to 01:00 is 11 AM to 1 PM; anything else gets the usual hour.
      final shifted = minutesOf(end) + 12 * 60;
      end = shifted > minutesOf(start) && shifted < 24 * 60 ? _hhmm(shifted) : null;
    }
    if (start != null && end == null && endDate == null) end = _hhmm((minutesOf(start) + 60).clamp(0, 24 * 60 - 1));
    if (raw['_guessedTime'] == true && start != null) {
      issues.add(const DraftIssue(IssueKind.guessed, 'Check the time; Den guessed AM or PM'));
    }

    String? rrule;
    final repeat = raw['repeat'];
    if (repeat is Map) {
      final rule = ruleFor(Map<String, Object?>.from(repeat), date);
      if (rule == null) {
        issues.add(const DraftIssue(IssueKind.guessed, 'Den couldn\'t read how it repeats, so it happens once'));
      } else {
        (rrule, date) = rule;
      }
    } else if (endDate != null && start != null && end != null && minutesOf(end) > minutesOf(start)) {
      // "Book fair, Nov 2 to 6, 8 AM to 3:30 PM" is the same hours each day, not one long event.
      rrule = 'FREQ=DAILY;UNTIL=${endDate.replaceAll('-', '')}';
      endDate = null;
    }

    final (ids, unknown) = people(raw['people']);
    final kind = _str(raw['kind'])?.toLowerCase() ?? eventKind(title);
    return DraftEvent(
      key: key,
      title: title,
      date: date,
      start: start,
      end: end,
      endDate: endDate,
      rrule: rrule,
      people: ids,
      location: _str(raw['location'], max: 300) ?? '',
      notes: _str(raw['notes'], max: 5000) ?? '',
      category: kind == null ? null : c.categories[kind],
      reminders: [
        for (final m in _list(raw['remindBefore']).map(_int).whereType<int>().toSet().take(10))
          if (m >= 0 && m <= 40320) m,
      ],
      issues: [...issues, ...unknown],
    );
  }

  List<DraftChore> chores(String key, Map<String, Object?> raw) {
    final title = _title(raw['title']);
    if (title == null) return const [];
    var date = day(raw['date']) ?? c.today;
    final issues = <DraftIssue>[];
    String? rrule;
    final repeat = raw['repeat'];
    if (repeat is Map) {
      final rule = ruleFor(Map<String, Object?>.from(repeat), date);
      if (rule == null) {
        issues.add(const DraftIssue(IssueKind.guessed, 'Den couldn\'t read how it repeats, so it happens once'));
      } else {
        (rrule, date) = rule;
      }
    }
    final (ids, unknown) = people(raw['people']);
    final points = (_int(raw['points']) ?? 0).clamp(0, 1000);
    DraftChore chore(String k, ChoreOwner owner) => DraftChore(
          key: k,
          title: title,
          owner: owner,
          date: date,
          rrule: rrule,
          dueTime: _time(raw['due']),
          points: points,
          icon: choreIcon(title),
          issues: [...issues, ...unknown],
        );
    if (ids.isEmpty) return [chore(key, const OwnerAnyone())];
    if (ids.length == 1) return [chore(key, OwnerMember(ids.single))];
    if (raw['takeTurns'] == true) return [chore(key, OwnerRotation(ids, 'week', date))];
    return [for (final (i, id) in ids.indexed) chore('$key.$i', OwnerMember(id))];
  }

  DraftItem? item(String key, Map<String, Object?> raw) {
    final text = _str(raw['text'], max: 300);
    if (text == null) return null;
    final listName = _str(raw['list'], max: _maxTitle);
    final store = _str(raw['store'], max: 100);
    final named = listName == null ? null : c.list(listName);
    final target = named ?? (listName == null ? c.groceries : null);
    final NewList? newList = target != null
        ? null
        : listName == null
            ? const NewList('Groceries', ListKind.shopping, pinned: true)
            : NewList(_sentence(listName.replaceAll(RegExp(r'\s+list$', caseSensitive: false), '')), _kindFor(listName));
    return DraftItem(
      key: key,
      text: _sentence(text),
      qty: _str(raw['qty'], max: 50),
      store: store == null ? null : c.store(store),
      listId: target?.id,
      newList: newList,
    );
  }

  DraftReminder? reminder(String key, Map<String, Object?> raw) {
    final text = _title(raw['text']);
    if (text == null) return null;
    final date = day(raw['date']) ?? c.today;
    final (ids, unknown) = people(raw['people']);
    return DraftReminder(
      key: key,
      text: text,
      date: date,
      time: _time(raw['time']),
      person: ids.firstOrNull ?? c.actorId,
      issues: unknown,
    );
  }

  static ListKind _kindFor(String name) {
    final n = name.toLowerCase();
    if (RegExp(r'pack|trip|camp|vacation').hasMatch(n)) return ListKind.packing;
    if (RegExp(r'grocer|shop|store|costco|target|market').hasMatch(n)) return ListKind.shopping;
    if (RegExp(r'meal|dinner|menu').hasMatch(n)) return ListKind.meal;
    return ListKind.checklist;
  }
}

String? _title(Object? raw) {
  final t = _str(raw, max: _maxTitle);
  return t == null ? null : _sentence(t);
}

/// "BOOK FAIR" reads "Book fair"; anything else keeps its own capitals, first letter raised.
String _sentence(String text) {
  var t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.isEmpty) return t;
  final letters = t.replaceAll(RegExp(r'[^A-Za-z]'), '');
  if (letters.length > 3 && letters == letters.toUpperCase()) t = t.toLowerCase();
  return t[0].toUpperCase() + t.substring(1);
}

List<Object?> _list(Object? raw) => raw is List ? raw : const [];

List<Map<String, Object?>> _maps(Object? raw) => [
      for (final e in _list(raw))
        if (e is Map) Map<String, Object?>.from(e),
    ];

String? _str(Object? raw, {int max = 1000}) {
  if (raw is! String) return null;
  final t = raw.trim();
  if (t.isEmpty || t.toLowerCase() == 'null') return null;
  return t.length > max ? '${t.substring(0, max - 1)}…' : t;
}

int? _int(Object? raw) => raw is int
    ? raw
    : raw is num
        ? raw.round()
        : raw is String
            ? int.tryParse(raw.trim())
            : null;

String? _date(Object? raw) {
  final t = _str(raw);
  if (t == null || t.length < 10) return null;
  final d = t.substring(0, 10);
  return isLocalDate(d) ? d : null;
}

/// `HH:mm`, from `17:00`, `5:00`, `5:00 PM` or `5pm`.
String? _time(Object? raw) {
  final t = _str(raw)?.toLowerCase().replaceAll('.', '');
  if (t == null) return null;
  final m = RegExp(r'^(\d{1,2})(?::(\d{2}))?(?::\d{2})?\s*(am|pm|a|p)?$').firstMatch(t);
  if (m == null) return null;
  var h = int.parse(m[1]!);
  final min = int.parse(m[2] ?? '0');
  final half = m[3];
  if (half != null) {
    if (h < 1 || h > 12) return null;
    if (half.startsWith('p') && h != 12) h += 12;
    if (half.startsWith('a') && h == 12) h = 0;
  }
  if (h > 23 || min > 59) return null;
  return _hhmm(h * 60 + min);
}

String _hhmm(int minutes) => '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
