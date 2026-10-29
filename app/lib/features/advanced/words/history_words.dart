import 'package:den_core/den_core.dart';

import '../../../app/family_reads.dart';
import '../../../app/words.dart';
import '../../calendar/calendar_words.dart';

/// Kinds of record people filter History by.
enum HistoryKind {
  events('Events', {RecordType.event, RecordType.eventException}),
  chores('Chores', {RecordType.chore, RecordType.completion}),
  lists('Lists', {RecordType.list, RecordType.item}),
  points('Stars', {RecordType.adjustment, RecordType.goal, RecordType.reward, RecordType.redemption}),
  family('Family', {
    RecordType.family,
    RecordType.member,
    RecordType.device,
    RecordType.category,
    RecordType.subscription,
    RecordType.connection,
  });

  const HistoryKind(this.label, this.types);
  final String label;
  final Set<String> types;
}

const _labels = {
  'title': 'Title',
  'notes': 'Notes',
  'location': 'Where',
  'category': 'Category',
  'start': 'Starts',
  'end': 'Ends',
  'allDay': 'All day',
  'rrule': 'Repeats',
  'assignees': 'Who',
  'reminders': 'Reminders',
  'rides': 'Rides',
  'countdown': 'Countdown',
  'cancelled': 'Canceled',
  'owner': 'Whose',
  'schedule': 'Schedule',
  'dueTime': 'Due',
  'points': 'Stars',
  'steps': 'Steps',
  'active': 'Active',
  'done': 'Done',
  'doneBy': 'Done by',
  'text': 'Item',
  'qty': 'Amount',
  'store': 'Store',
  'checked': 'Checked',
  'checkedBy': 'Checked by',
  'pinned': 'Pinned',
  'needBy': 'Needed by',
  'name': 'Name',
  'role': 'Role',
  'marker': 'Color',
  'animal': 'Animal',
  'picture': 'Picture',
  'birthday': 'Birthday',
  'grants': 'Can edit',
  'timezone': 'Time zone',
  'weekStart': 'Week starts',
  'cost': 'Cost',
  'target': 'Target',
  'reward': 'Reward',
  'status': 'Status',
  'delta': 'Stars',
  'reason': 'Reason',
  'approved': 'Approved',
  'revoked': 'Revoked',
  'icon': 'Icon',
  'kind': 'Kind',
  'label': 'Label',
};

/// A field's name for people: "Starts", "Where", "Needed by".
String fieldLabel(String field) {
  final known = _labels[field];
  if (known != null) return known;
  final words = field.replaceAllMapped(RegExp(r'[A-Z]'), (m) => ' ${m[0]!.toLowerCase()}').trim();
  return words.isEmpty ? field : '${words[0].toUpperCase()}${words.substring(1)}';
}

/// Whether a field is bookkeeping that History doesn't show.
bool hiddenField(String field) =>
    field.startsWith('_') ||
    const {
      'signIn',
      'pubkey',
      'xpub',
      'tokenHash',
      'order',
      'founderDevice',
      'tz',
      'source',
      'event',
      'occurrence',
      'list',
      'chore',
      'date',
      'patch',
    }.contains(field);

/// Before and after of one change, in words; null means "none".
(String?, String?) diffWords(FamilyReads app, String type, FieldDiff diff) {
  final f = app.formats;
  final before = diff.before;
  final after = diff.after;
  if ((diff.field == 'start' || diff.field == 'end') && (before is num || after is num)) {
    final b = (before as num?)?.toInt();
    final a = (after as num?)?.toInt();
    final sameDay = b != null && a != null && f.localDate(b) == f.localDate(a);
    String at(int ms) => sameDay ? f.time(ms) : '${f.short(f.localDate(ms))}, ${f.time(ms)}';
    return (b == null ? null : at(b), a == null ? null : at(a));
  }
  return (valueWords(app, type, diff.field, before), valueWords(app, type, diff.field, after));
}

/// One field value in words, or null when it's empty.
String? valueWords(FamilyReads app, String type, String field, Object? value) {
  final f = app.formats;
  final den = app.den;
  if (value == null) return null;
  if (value is String && value.trim().isEmpty) return null;
  if (value is bool) return value ? 'Yes' : 'No';
  switch (field) {
    case 'assignees':
    case 'members':
      final ids = (value as List?)?.cast<String>() ?? const [];
      return whoWords(app, ids);
    case 'member':
    case 'doneBy':
    case 'checkedBy':
    case 'by':
    case 'driver':
    case 'decidedBy':
    case 'approvedBy':
    case 'assignee':
      return app.memberById(value as String?)?.name ?? 'Someone';
    case 'category':
      return den.category(value as String)?.name ?? 'A removed category';
    case 'reminders':
      final list = [...((value as List?) ?? const []).map((e) => (e as num).toInt())]..sort();
      return list.isEmpty ? null : list.map((m) => reminderWords(m, due: type == RecordType.chore)).join(', ');
    case 'rides':
      final legs = ((value as List?) ?? const []).map((e) => Map<String, Object?>.from(e as Map));
      final words = [
        for (final leg in legs)
          '${legWords(leg['leg'] as String? ?? 'to')}: ${app.memberById(leg['driver'] as String?)?.name ?? 'nobody'}',
      ];
      return words.isEmpty ? null : words.join(', ');
    case 'rrule':
      return describeRrule(value as String, f, startDate: app.today, weekStart: den.family?.weekStart ?? 0);
    case 'dueTime':
      final minutes = f.parseHhmm(value as String);
      return minutes == null ? value : f.clock(minutes);
    case 'needBy':
    case 'birthday':
      return value is String && value.length == 10 ? f.short(value) : '$value';
    case 'owner':
      final raw = Map<String, Object?>.from(value as Map);
      return switch (raw['kind']) {
        'member' => app.memberById(raw['id'] as String?)?.name ?? 'Someone',
        'rotation' => 'Taking turns',
        _ => 'Anyone',
      };
    case 'schedule':
      final raw = Map<String, Object?>.from(value as Map);
      if (raw['once'] is String) return 'Once, ${f.short(raw['once']! as String)}';
      final start = raw['start'] as String? ?? app.today;
      return describeRrule(raw['rrule'] as String?, f, startDate: start, weekStart: den.family?.weekStart ?? 0);
    case 'steps':
      if (value is List) return value.isEmpty ? null : '${value.length} ${value.length == 1 ? 'step' : 'steps'}';
      if (value is Map) {
        final checked = value.values.where((v) => v != null).length;
        return '$checked checked';
      }
    case 'weekStart':
      return value is num ? f.weekdayName(value.toInt() % 7, long: true) : '$value';
    case 'marker':
    case 'animal':
    case 'picture':
    case 'role':
    case 'status':
    case 'kind':
      final text = '$value';
      return text.isEmpty ? null : '${text[0].toUpperCase()}${text.substring(1)}';
    case 'grants':
      final list = ((value as List?) ?? const []).cast<String>();
      return list.isEmpty ? 'Nothing' : list.join(', ');
  }
  if (value is num) return '$value';
  if (value is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return f.short(value);
  if (value is String) return value.length > 80 ? '${value.substring(0, 79)}…' : value;
  if (value is List) return value.isEmpty ? null : '${value.length} ${value.length == 1 ? 'entry' : 'entries'}';
  return null;
}

/// Where an entry leads when tapped, or null when there's no page for it.
String? routeForRecord(FamilyReads app, String type, String id) {
  switch (type) {
    case RecordType.event:
      return app.den.event(id) == null ? null : '/event/$id';
    case RecordType.chore:
      return app.den.chore(id) == null ? null : '/chore/$id';
    case RecordType.completion:
      final at = id.lastIndexOf('@');
      if (at <= 0) return null;
      final chore = id.substring(0, at);
      return app.den.chore(chore) == null ? null : '/chore/$chore?date=${id.substring(at + 1)}';
    case RecordType.list:
      return app.den.list(id) == null ? null : '/lists/$id';
    case RecordType.item:
      for (final state in app.den.lists) {
        if (state.items.any((i) => i.id == id)) return '/lists/${state.list.id}';
      }
      return null;
    case RecordType.member:
      return app.den.member(id) == null ? '/family' : '/family/member/$id';
    case RecordType.device:
      return '/family';
    case RecordType.adjustment:
    case RecordType.goal:
    case RecordType.reward:
    case RecordType.redemption:
      return '/points';
  }
  return null;
}

/// What a History row says: the verb, the title, and the field changes worth showing.
class HistoryLine {
  const HistoryLine(this.verb, this.title, this.diffs);
  final String verb;
  final String title;
  final List<FieldDiff> diffs;
}

Object? _after(HistoryEntry e, String field) {
  for (final d in e.diffs) {
    if (d.field == field) return d.after;
  }
  return null;
}

bool _same(Object? a, Object? b) => a == b || (a != null && b != null && a.toString() == b.toString());

/// Reads an entry for people. A change to one occurrence of a repeating event reads "changed
/// Soccer practice on Oct 20" with the fields it overrode; "canceled" when it was removed.
HistoryLine historyLine(FamilyReads app, HistoryEntry e) {
  final f = app.formats;
  if (e.type == RecordType.eventException) {
    FieldDiff? find(String field) {
      for (final d in e.diffs) {
        if (d.field == field) return d;
      }
      return null;
    }

    final cancelled = find('cancelled');
    final occurrence = _after(e, 'occurrence');
    final on = occurrence is num ? ' on ${f.monthDay(f.localDate(occurrence.toInt()), relativeTo: app.today)}' : '';
    final verb = cancelled?.after == true && cancelled?.before != true
        ? 'canceled'
        : cancelled?.after == false && cancelled?.before == true
        ? 'brought back'
        : 'changed';
    // The engine writes a patch whole, or one key at a time as "patch.<field>".
    final patch = find('patch');
    final before = patch?.before is Map ? Map<String, Object?>.from(patch!.before! as Map) : <String, Object?>{};
    final after = patch?.after is Map ? Map<String, Object?>.from(patch!.after! as Map) : <String, Object?>{};
    for (final d in e.diffs) {
      if (!d.field.startsWith('patch.')) continue;
      final key = d.field.substring(6);
      before[key] = d.before;
      after[key] = d.after;
    }
    // A first change to one day has nothing before it in the patch; the series' own time is
    // what it was.
    final series = app.den.event(_after(e, 'event') as String? ?? '');
    if (occurrence is num && series != null) {
      if (after.containsKey('start') && before['start'] == null) before['start'] = occurrence.toInt();
      if (after.containsKey('end') && before['end'] == null) {
        before['end'] = occurrence.toInt() + series.end - series.start;
      }
    }
    final diffs = verb == 'changed'
        ? [
            for (final key in {...before.keys, ...after.keys})
              if (!_same(before[key], after[key]) && !hiddenField(key)) FieldDiff(key, before[key], after[key]),
          ]
        : const <FieldDiff>[];
    return _rideLine(app, e, diffs, '${e.title}$on') ?? HistoryLine(verb, '${e.title}$on', diffs);
  }
  if (e.type == RecordType.adjustment && (e.verb == 'gave' || e.verb == 'took')) {
    final member = app.memberById(_after(e, 'member') as String?)?.name ?? 'someone';
    final delta = ((_after(e, 'delta') as num?) ?? 0).toInt().abs();
    final stars = '$delta ${delta == 1 ? 'star' : 'stars'}';
    final reason = e.title.isEmpty ? '' : ' for ${e.title}';
    return HistoryLine(e.verb, e.verb == 'gave' ? '$member $stars$reason' : '$stars from $member$reason', const []);
  }
  if (e.type == RecordType.completion && (e.verb == 'checked' || e.verb == 'unchecked')) {
    final at = e.rid.lastIndexOf('@');
    final choreId = _after(e, 'chore') as String? ?? (at > 0 ? e.rid.substring(0, at) : '');
    final steps = app.den.chore(choreId)?.steps ?? const <ChoreStep>[];
    final ids = <String>{
      for (final d in e.diffs)
        if (d.field.startsWith('steps.')) d.field.substring(6),
      for (final d in e.diffs)
        if (d.field == 'steps' && d.after is Map) ...(d.after! as Map).keys.cast<String>(),
    };
    final names = [for (final step in steps) if (ids.contains(step.id)) step.text];
    if (names.isNotEmpty) return HistoryLine(e.verb, '${joinWords(names)} (${e.title})', const []);
  }
  final diffs = e.verb == 'changed'
      ? [
          for (final d in e.diffs)
            if (!hiddenField(d.field) && !d.field.contains('.') && !_same(d.before, d.after)) d,
        ]
      : const <FieldDiff>[];
  if (e.type == RecordType.event) {
    final ride = _rideLine(app, e, diffs, e.title);
    if (ride != null) return ride;
  }
  return HistoryLine(e.verb, e.title, diffs);
}

/// "took the drop-off for Swim lesson", "let go of the pick-up for Soccer practice": a change
/// that only set or cleared the actor's own ride, said the way Today offers it.
HistoryLine? _rideLine(FamilyReads app, HistoryEntry e, List<FieldDiff> diffs, String title) {
  if (diffs.length != 1 || diffs.single.field != 'rides' || e.actor == null) return null;
  List<Map<String, Object?>> legs(Object? v) => [
        for (final r in (v is List ? v : const [])) Map<String, Object?>.from(r as Map),
      ];
  final before = {for (final r in legs(diffs.single.before)) r['leg']: r['driver']};
  final after = {for (final r in legs(diffs.single.after)) r['leg']: r['driver']};
  final changed = [for (final leg in {...before.keys, ...after.keys}) if (before[leg] != after[leg]) leg];
  if (changed.length != 1 || !before.containsKey(changed.single) || !after.containsKey(changed.single)) return null;
  final leg = changed.single as String? ?? 'to';
  final words = legWords(leg).toLowerCase();
  if (before[leg] == null && after[leg] == e.actor) return HistoryLine('took the', '$words for $title', const []);
  if (before[leg] == e.actor && after[leg] == null) return HistoryLine('let go of the', '$words for $title', const []);
  return null;
}

/// Changes the engine makes to keep a series in order (exceptions moved along with a series or
/// cleared with it) that would read as noise next to the change the person made.
Set<HistoryEntry> bookkeeping(List<HistoryEntry> entries) {
  final eventChanges = <String, List<HistoryEntry>>{};
  for (final e in entries) {
    if (e.type == RecordType.event) eventChanges.putIfAbsent(e.rid, () => []).add(e);
  }
  return {
    for (final e in entries)
      if (e.type == RecordType.eventException &&
          (e.verb == 'removed' ||
              (eventChanges[_after(e, 'event')] ?? const []).any(
                (x) => x.device == e.device && (x.when.millis - e.when.millis).abs() <= 2000,
              )))
        e,
  };
}

/// What a History row says after the person's name, as one plain sentence: "moved Soccer
/// practice to 6:00 PM", "renamed Dishes to Dinner dishes", "made Dishes worth 3 stars",
/// "added Parent-teacher conference". A change to several things at once says "changed Soccer
/// practice"; the row shows each field on a tap.
String historySentence(FamilyReads app, HistoryEntry e, HistoryLine line) {
  final title = line.title;
  final diffs = line.diffs;
  if (line.verb != 'changed' || diffs.isEmpty) return '${line.verb} $title';
  final f = app.formats;
  FieldDiff? find(String field) => diffs.where((d) => d.field == field).firstOrNull;
  final fields = {for (final d in diffs) d.field};

  // A time moved, keeping how long it lasts: "moved Soccer practice to 6:00 PM", to another
  // day "to Tue, Oct 20 at 6:00 PM", and to a new place too "... at Field 4".
  final start = find('start'), end = find('end');
  String? movedTo;
  if (start != null && start.before is num && start.after is num) {
    final before = (start.before! as num).toInt(), after = (start.after! as num).toInt();
    final sameLength = end == null ||
        (end.before is num && end.after is num && (end.after! as num) - (end.before! as num) == after - before);
    if (sameLength) {
      movedTo = f.localDate(before) == f.localDate(after) ? f.time(after) : '${f.short(f.localDate(after))} at ${f.time(after)}';
    }
  }
  if (movedTo != null && fields.difference({'start', 'end', 'location'}).isEmpty) {
    final place = find('location')?.after;
    if (!fields.contains('location')) return 'moved $title to $movedTo';
    if (place is String && place.trim().isNotEmpty) return 'moved $title to $movedTo at ${place.trim()}';
  }
  if (fields.length != 1) return 'changed $title';

  final only = diffs.single;
  final (before, after) = diffWords(app, e.type, only);
  String stars(String? n) => n == null || n == '0' ? 'no stars' : '$n ${n == '1' ? 'star' : 'stars'}';
  switch (only.field) {
    case 'title' || 'text' || 'name' when before != null && after != null:
      return 'renamed $before to $after';
    case 'location':
      if (after == null) return 'took the place off $title';
      return before == null ? 'set $title at $after' : 'moved $title to $after';
    case 'end' when after != null:
      return 'made $title end at $after';
    case 'points':
      return 'made $title worth ${stars(after)}';
    case 'cost':
      return 'made $title cost ${stars(after)}';
    case 'dueTime':
      return after == null ? 'took the due time off $title' : 'made $title due by $after';
    case 'owner':
      if (after == 'Anyone') return "made $title anyone's";
      if (after == 'Taking turns') return 'made $title take turns';
      return 'gave $title to $after';
    case 'assignees':
      return 'made $title for ${after == 'Everyone' ? 'everyone' : after}';
    case 'rrule' || 'schedule':
      if (after == null) return 'made $title happen once';
      return 'made $title repeat ${_lowerFirst(after).replaceFirst('repeats ', '')}';
    case 'allDay':
      return after == 'Yes' ? 'made $title all day' : 'gave $title a time';
    case 'reminders':
      return after == null ? 'took the reminders off $title' : 'set $title to remind ${_lowerFirst(after)}';
    case 'qty' when after != null:
      return 'changed $title to $after';
    case 'store':
      return after == null ? 'took $title off its store' : 'moved $title to $after';
    case 'pinned':
      return after == 'Yes' ? 'pinned $title to Today' : 'took $title off Today';
    case 'needBy':
      return after == null ? 'took the date off $title' : 'made $title needed by $after';
  }
  return 'changed the ${fieldLabel(only.field).toLowerCase()} for $title';
}

/// "Every Tuesday" as it reads mid-sentence: "every Tuesday".
String _lowerFirst(String text) => text.isEmpty ? text : '${text[0].toLowerCase()}${text.substring(1)}';
