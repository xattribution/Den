import 'package:den_core/den_core.dart';

import '../../../app/family_reads.dart';
import '../../calendar/calendar_words.dart';
import '../../family/family.dart' show accessEndedWords, privacyNow;

/// Kinds of record people filter History by.
enum HistoryKind {
  events('Events', {RecordType.event, RecordType.eventException}),
  chores('Chores', {RecordType.chore, RecordType.completion}),
  lists('Lists', {RecordType.list, RecordType.item}),
  points('Points', {RecordType.adjustment, RecordType.goal, RecordType.reward, RecordType.redemption}),
  family('Family', {
    RecordType.family,
    RecordType.member,
    RecordType.device,
    RecordType.category,
    RecordType.subscription,
    RecordType.connection,
    RecordType.photo,
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
  'points': 'Points',
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
  'until': 'Has Den until',
  'grants': 'Can edit',
  'timezone': 'Time zone',
  'weekStart': 'Week starts',
  'cost': 'Cost',
  'target': 'Target',
  'reward': 'Reward',
  'status': 'Status',
  'delta': 'Points',
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
      'recovery',
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
      return list.isEmpty ? null : list.map(reminderWords).join(', ');
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
    case 'picture' when value is String && Picture.photoIdOf(value) != null:
      return 'A photo';
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
  final recovered = _recoveryLine(app, e);
  if (recovered != null) return recovered;
  final controls = _controlsLine(app, e);
  if (controls != null) return controls;
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
    final points = '$delta ${delta == 1 ? 'point' : 'points'}';
    final reason = e.title.isEmpty ? '' : ': ${e.title}';
    return HistoryLine(e.verb, e.verb == 'gave' ? '$member $points$reason' : '$points from $member$reason', const []);
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

/// Recovery, said so nobody gets in unseen (den_core's recovery.dart): a parent's new phone
/// "was let in with Alex's recovery words" or "by the hub's recovery" (the row's name is the
/// new phone's, since nobody acted for it); a parent "set up new recovery words"; the hub's help
/// turned on or off.
HistoryLine? _recoveryLine(FamilyReads app, HistoryEntry e) {
  final value = _after(e, 'recovery');
  if (value is! Map) return null;
  switch (e.type) {
    case RecordType.device:
      if (value['kind'] == 'hub') return const HistoryLine('was let in by', "the hub's recovery", []);
      final name = app.memberById(value['member'] as String?)?.name;
      return HistoryLine('was let in with', name == null ? 'recovery words' : "$name's recovery words", const []);
    case RecordType.member:
      final own = e.actor == e.rid;
      if (value['on'] == true) return HistoryLine('set up', own ? 'new recovery words' : 'recovery words for ${e.title}', const []);
      return HistoryLine('took away', own ? 'their recovery words' : "${e.title}'s recovery words", const []);
    case RecordType.family:
      return value['on'] == true
          ? const HistoryLine('let', 'the hub help a parent get back in', [])
          : const HistoryLine('stopped', 'the hub helping a parent get back in', []);
  }
  return null;
}

/// Parental controls, said the way their switches say them: "changed this: parents can now see
/// things you mark Just me" (to the teen it's about), "changed this: Maya can trade stars for
/// rewards without asking"; a sitter's device removed after their last day ("removed Sam's
/// phone: Sam's access ended Sunday"); a photo added.
HistoryLine? _controlsLine(FamilyReads app, HistoryEntry e) {
  if (e.type == RecordType.photo && e.verb == 'added') {
    return HistoryLine('added', 'a photo of ${app.memberById(_after(e, 'member') as String?)?.name ?? 'someone'}', const []);
  }
  if (e.type == RecordType.device && e.verb == 'removed') {
    final owner = app.memberById(app.den.device(e.rid)?.member);
    final until = owner?.until;
    if (owner == null || until == null || owner.role != Role.guest) return null;
    if (app.formats.localDate(e.when.millis).compareTo(until) <= 0) return null;
    return HistoryLine('removed', '${e.title}: ${accessEndedWords(owner.name, until, app.formats, app.today)}', const []);
  }
  if (e.type != RecordType.family) return null;
  bool sees(Object? v) => (v is Map ? v['parentsSeePrivate'] : null) as bool? ?? true;
  for (final d in e.diffs) {
    if (!d.field.startsWith('oversight.')) continue;
    final key = d.field.substring('oversight.'.length);
    final dot = key.indexOf('.');
    final who = app.memberById(dot < 0 ? key : key.substring(0, dot));
    if (who == null) continue;
    final name = who.name;
    if (dot < 0) {
      if (sees(d.before) == sees(d.after)) continue;
      final you = app.me?.id == who.id;
      return HistoryLine('changed this:', privacyNow(parentsSee: sees(d.after), you: you, name: name), const []);
    }
    final on = d.after != false;
    switch (key.substring(dot + 1)) {
      case OversightSetting.rewardsNeedOk:
        return HistoryLine(
          'changed this:',
          on ? "$name's rewards need a parent's OK" : '$name can trade stars for rewards without asking',
          const [],
        );
      case OversightSetting.ownPicture:
        return HistoryLine('changed this:', on ? '$name can change their own picture' : "only parents change $name's picture", const []);
    }
  }
  return null;
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
