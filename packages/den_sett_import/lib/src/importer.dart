import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// What an import brought over and what it left behind, written for the parent who ran it.
class SettImportReport {
  final Map<String, int> imported = {};
  final Map<String, int> skipped = {};
  final List<String> notes = [];

  void _add(String what, [int n = 1]) => imported.update(what, (v) => v + n, ifAbsent: () => n);
  void _skip(String what, [int n = 1]) => skipped.update(what, (v) => v + n, ifAbsent: () => n);

  @override
  String toString() => [
        'Imported: ${imported.entries.map((e) => '${e.value} ${e.key}').join(', ')}',
        if (skipped.isNotEmpty) 'Left behind: ${skipped.entries.map((e) => '${e.value} ${e.key}').join(', ')}',
        ...notes,
      ].join('\n');
}

/// Reads Sett's database at [coordDbPath] and recreates its family in [den], which must already
/// have a family and an acting parent. Sett members whose names match a Den member (case
/// insensitive) are merged into that member instead of being added again.
Future<SettImportReport> importSettDatabase(String coordDbPath, Den den) async {
  final actor = den.actor;
  if (!den.hasFamily || actor == null || !actor.isParent) {
    throw const PermissionDenied('Importing from Sett needs a parent signed in on this device.');
  }
  tzdata.initializeTimeZones();
  final db = sqlite3.open(coordDbPath, mode: OpenMode.readOnly);
  try {
    return await _Importer(db, den).run();
  } finally {
    db.close();
  }
}

class _Importer {
  _Importer(this.db, this.den);

  final Database db;
  final Den den;
  final report = SettImportReport();

  final members = <String, String>{};
  final events = <String, String>{};
  final chores = <String, String>{};
  final categories = <String, String>{};
  late tz.Location zone;

  Future<SettImportReport> run() async {
    final household = db.select('SELECT name, timezone FROM households LIMIT 1');
    if (household.isEmpty) {
      report.notes.add('That file has no Sett family in it.');
      return report;
    }
    zone = _location(household.first['timezone'] as String? ?? den.family?.timezone ?? 'UTC');
    final settName = household.first['name'] as String;
    if (settName != den.family?.name) {
      report.notes.add('Sett called the family "$settName"; Den keeps "${den.family?.name}".');
    }

    await _members();
    await _events();
    await _chores();
    await _completions();
    await _lists();
    await _points();
    _leftBehind();
    return report;
  }

  // ------------------------------------------------------------------ members

  Future<void> _members() async {
    final rows = db.select('SELECT * FROM members WHERE deleted_at IS NULL ORDER BY sort_order, created_at');
    var index = 0;
    for (final row in rows) {
      final name = row['name'] as String;
      final existing = den.members.where((m) => m.name.toLowerCase() == name.toLowerCase()).firstOrNull;
      if (existing != null) {
        members[row['id'] as String] = existing.id;
        report._add('people matched by name');
        index++;
        continue;
      }
      final isParent = row['role'] == 'parent';
      final grants = _list(row['grants_json']);
      final id = await den.addMember(
        name: name,
        role: isParent ? Role.parent : Role.kid,
        tier: isParent
            ? null
            : switch (row['ui_level']) {
                'little' => Tier.little,
                'teen' => Tier.teen,
                _ => Tier.big,
              },
        marker: _marker(row['color'] as String?, index),
        animal: _animal(row['avatar'] as String?, index),
        grants: {
          if (grants.contains('event.manage')) Grant.events,
          if (grants.contains('task.manage')) Grant.chores,
          if (grants.contains('checklist.manage')) Grant.lists,
        },
      );
      members[row['id'] as String] = id;
      report._add('people');
      index++;
    }
    if (rows.isNotEmpty) {
      report.notes.add("Sign-in PINs and picture patterns can't be carried over; set them again in Family.");
    }
  }

  // ------------------------------------------------------------------ calendar

  Future<String?> _category(String? settCategory) async {
    if (settCategory == null) return null;
    final known = categories[settCategory];
    if (known != null) return known;
    final (name, icon) = switch (settCategory) {
      'school' => ('School', 'school'),
      'sports' => ('Sports', 'sports'),
      'work' => ('Work', 'work'),
      'appointment' => ('Appointment', 'health'),
      'birthday' => ('Birthday', 'birthday'),
      'holiday' => ('Holiday', 'holiday'),
      'family' => ('Family', 'family'),
      _ => ('Other', 'calendar'),
    };
    final existing = den.categories.where((c) => c.name.toLowerCase() == name.toLowerCase()).firstOrNull;
    final id = existing?.id ?? await den.addCategory(name: name, icon: icon);
    categories[settCategory] = id;
    return id;
  }

  /// Sett's "private" meant the creator plus every parent, which is Den's parents space.
  Audience _audience(Object? visibility, Object? createdBy) =>
      visibility == 'private' ? Audience.parents : Audience.everyone;

  Future<void> _events() async {
    final rows = db.select('SELECT * FROM events WHERE deleted_at IS NULL ORDER BY start_at');
    final hasSource = _hasColumn('events', 'source_sub_id');
    final hasVisibility = _hasColumn('events', 'visibility');
    for (final row in rows) {
      if (hasSource && row['source_sub_id'] != null) {
        report._skip('events from subscribed calendars (add those links again in Den)');
        continue;
      }
      final id = row['id'] as String;
      final assignees = db
          .select('SELECT member_id FROM event_assignees WHERE event_id = ?', [id])
          .map((r) => members[r['member_id']])
          .whereType<String>()
          .toList();
      final reminders = db
          .select("SELECT offset_minutes FROM reminders WHERE entity_type = 'event' AND entity_id = ?", [id])
          .map((r) => r['offset_minutes'] as int)
          .toList();
      final newId = await den.addEvent(
        title: row['title'] as String,
        notes: row['description'] as String? ?? '',
        location: row['location'] as String? ?? '',
        start: row['start_at'] as int,
        end: row['end_at'] as int,
        allDay: (row['all_day'] as int? ?? 0) == 1,
        tz: row['timezone'] as String?,
        rrule: row['rrule'] as String?,
        assignees: assignees,
        category: await _category(row['category'] as String?),
        reminders: reminders,
        audience: hasVisibility ? _audience(row['visibility'], row['created_by']) : Audience.everyone,
      );
      events[id] = newId;
      report._add('events');

      for (final ex in db.select('SELECT * FROM event_exceptions WHERE event_id = ?', [id])) {
        final occurrence = ex['occurrence_start'] as int;
        if (ex['kind'] == 'cancelled') {
          await den.deleteEvent(newId, scope: EditScope.one, occurrence: occurrence);
        } else {
          final override = ex['override_json'] == null
              ? <String, Object?>{}
              : Map<String, Object?>.from(jsonDecode(ex['override_json'] as String) as Map);
          await den.updateEvent(newId, await _eventPatch(override), scope: EditScope.one, occurrence: occurrence);
        }
        report._add('changed or canceled repeats');
      }
    }
  }

  Future<Map<String, Object?>> _eventPatch(Map<String, Object?> o) async => {
        if (o['title'] != null) 'title': o['title'],
        if (o['description'] != null) 'notes': o['description'],
        if (o['location'] != null) 'location': o['location'],
        if (o['category'] != null) 'category': await _category(o['category'] as String),
        if (o['startAt'] != null) 'start': o['startAt'],
        if (o['endAt'] != null) 'end': o['endAt'],
      };

  // ------------------------------------------------------------------ chores

  Future<void> _chores() async {
    final hasSteps = _hasColumn('tasks', 'steps_json');
    final hasVisibility = _hasColumn('tasks', 'visibility');
    for (final row in db.select('SELECT * FROM tasks WHERE deleted_at IS NULL ORDER BY created_at')) {
      final dueAt = row['due_at'] as int?;
      final repeat = row['repeat'] as String?;
      final created = _date(row['created_at'] as int);
      final schedule = repeat == null
          ? ChoreSchedule.once(dueAt == null ? created : _date(dueAt))
          : ChoreSchedule.repeating(_rrule(repeat), created);
      final assignee = members[row['assignee_id']];
      final steps = hasSteps ? _steps(row['steps_json']) : const <ChoreStep>[];
      final id = await den.addChore(
        title: row['title'] as String,
        notes: row['notes'] as String? ?? '',
        icon: _pictogram(row['icon'] as String?),
        owner: assignee == null ? const OwnerAnyone() : OwnerMember(assignee),
        schedule: schedule,
        dueTime: repeat == null && dueAt != null ? _time(dueAt) : null,
        points: row['points'] as int? ?? 0,
        steps: steps,
        audience: hasVisibility ? _audience(row['visibility'], row['created_by']) : Audience.everyone,
      );
      chores[row['id'] as String] = id;
      report._add('chores');
    }
  }

  List<ChoreStep> _steps(Object? json) {
    if (json == null) return const [];
    final raw = jsonDecode(json as String) as List;
    return [
      for (final step in raw)
        if (step is String)
          ChoreStep(id: newId(), text: step)
        else
          ChoreStep(
            id: newId(),
            text: (step as Map)['text'] as String? ?? '',
            owner: members[step['assigneeId']],
            points: (step['points'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  /// Sett repeats were `daily`, `weekdays`, or weekday numbers like `0,3,5` (0 = Sunday).
  static String _rrule(String repeat) {
    if (repeat == 'daily') return 'FREQ=DAILY';
    if (repeat == 'weekdays') return 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR';
    const days = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
    final picked = repeat
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .where((d) => d >= 0 && d < 7)
        .map((d) => days[d]);
    return 'FREQ=WEEKLY;BYDAY=${picked.join(',')}';
  }

  Future<void> _completions() async {
    for (final row in db.select('SELECT * FROM task_completions ORDER BY completed_at')) {
      final chore = chores[row['task_id']];
      if (chore == null) continue;
      final key = row['occurrence_date'] as String? ?? '';
      final date = key.isEmpty ? _date(row['completed_at'] as int) : key;
      final completer = members[row['completed_by']];
      final owner = den.chore(chore)?.owner;
      if (owner is OwnerAnyone && completer != null) {
        // Points for an "anyone" chore belong to whoever did it, so the day is theirs.
        await den.swapForDay(chore, date, completer);
      }
      await den.setChoreDone(chore, date, true);
      report._add('chore check-offs');
    }
  }

  // ------------------------------------------------------------------ lists

  Future<void> _lists() async {
    final hasNeedBy = _hasColumn('checklists', 'need_by');
    final hasEvent = _hasColumn('checklists', 'linked_event_id');
    final hasStore = _hasColumn('checklist_items', 'store');
    for (final row in db.select('SELECT * FROM checklists WHERE deleted_at IS NULL ORDER BY sort_order, created_at')) {
      final kind = switch (row['kind']) {
        'shopping' => ListKind.shopping,
        'packing' => ListKind.packing,
        'meal' => ListKind.meal,
        _ => ListKind.checklist,
      };
      final linked = hasEvent ? events[row['linked_event_id']] : null;
      final needBy = hasNeedBy ? row['need_by'] as int? : null;
      final id = await den.addList(
        title: row['title'] as String,
        kind: kind,
        lifecycle: linked != null
            ? ListLifecycle.event
            : needBy != null
                ? ListLifecycle.dated
                : ListLifecycle.running,
        needBy: needBy == null ? null : _date(needBy),
        event: linked,
        pinned: (row['pinned_to_dashboard'] as int? ?? 0) == 1,
      );
      report._add('lists');
      final items = db.select(
        'SELECT * FROM checklist_items WHERE checklist_id = ? ORDER BY sort_order, created_at',
        [row['id']],
      );
      for (final item in items) {
        final itemId = await den.addItem(
          id,
          text: item['text'] as String,
          qty: item['quantity'] as String?,
          store: hasStore ? item['store'] as String? : null,
        );
        if ((item['checked'] as int? ?? 0) == 1) await den.setItemChecked(itemId, true);
        report._add('list items');
      }
    }
  }

  // ------------------------------------------------------------------ points

  Future<void> _points() async {
    if (_hasTable('points_ledger')) {
      final manual = db.select("SELECT * FROM points_ledger WHERE source = 'manual' ORDER BY created_at");
      for (final row in manual) {
        final member = members[row['member_id']];
        if (member == null) continue;
        await den.adjustPoints(member, row['delta'] as int, row['reason'] as String? ?? 'From Sett');
        report._add('point adjustments');
      }
    }
    if (_hasTable('point_goals')) {
      for (final row in db.select('SELECT * FROM point_goals WHERE deleted_at IS NULL')) {
        final ids = row['member_ids_json'] == null
            ? null
            : _list(row['member_ids_json']).map((id) => members[id]).whereType<String>().toList();
        final endsAt = row['ends_at'] as int?;
        await den.addGoal(
          title: row['title'] as String,
          target: row['target'] as int,
          mode: row['mode'] == 'race' ? GoalMode.race : GoalMode.target,
          members: ids,
          start: _date(row['starts_at'] as int),
          end: endsAt == null ? null : _date(endsAt),
          repeat: row['repeat'] == 'monthly' ? GoalRepeat.monthly : GoalRepeat.none,
          reward: row['reward'] as String? ?? '',
        );
        report._add('goals');
      }
    }
  }

  void _leftBehind() {
    int count(String table) => _hasTable(table) ? db.select('SELECT COUNT(*) AS n FROM $table').first['n'] as int : 0;
    final peers = count('peers');
    if (peers > 0) report._skip('connected families (connect them again; Den pairs with stronger keys)', peers);
    final tokens = _hasTable('api_tokens') ? db.select('SELECT COUNT(*) AS n FROM api_tokens WHERE revoked_at IS NULL').first['n'] as int : 0;
    if (tokens > 0) report._skip('AI tokens (create new ones in Settings; they now have scopes)', tokens);
    final displays = _hasTable('device_tokens') ? db.select('SELECT COUNT(*) AS n FROM device_tokens WHERE revoked_at IS NULL').first['n'] as int : 0;
    if (displays > 0) report._skip('display links (set the tablets up again from Family > Devices)', displays);
    final messages = count('fed_messages');
    if (messages > 0) report._skip('messages with other families', messages);
    final history = count('audit_log');
    if (history > 0) report._skip("history entries (Den starts its own history; Sett's stays in coord.db)", history);
  }

  // ------------------------------------------------------------------ helpers

  bool _hasTable(String name) =>
      db.select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [name]).isNotEmpty;

  bool _hasColumn(String table, String column) =>
      db.select('PRAGMA table_info($table)').any((r) => r['name'] == column);

  static List<String> _list(Object? json) =>
      json == null ? const [] : [...(jsonDecode(json as String) as List).map((e) => e.toString())];

  static tz.Location _location(String name) {
    try {
      return tz.getLocation(name);
    } on Object {
      return tz.UTC;
    }
  }

  String _date(int ms) {
    final d = tz.TZDateTime.fromMillisecondsSinceEpoch(zone, ms);
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _time(int ms) {
    final d = tz.TZDateTime.fromMillisecondsSinceEpoch(zone, ms);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  /// Sett colors were hex strings; pick the family color with the nearest hue.
  static Marker _marker(String? hex, int index) {
    if (hex == null || !RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(hex)) {
      return Marker.values[index % Marker.values.length];
    }
    final v = int.parse(hex.replaceFirst('#', ''), radix: 16);
    final hue = _hue((v >> 16) & 255, (v >> 8) & 255, v & 255);
    // The family colors' own hues.
    const hues = {
      Marker.coral: 1.0,
      Marker.tangerine: 30.0,
      Marker.sunshine: 49.0,
      Marker.grass: 126.0,
      Marker.aqua: 180.0,
      Marker.sky: 205.0,
      Marker.lavender: 262.0,
      Marker.bubblegum: 334.0,
    };
    Marker best = Marker.sky;
    var bestDistance = 999.0;
    hues.forEach((marker, h) {
      final d = (hue - h).abs();
      final distance = d > 180 ? 360 - d : d;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = marker;
      }
    });
    return best;
  }

  static double _hue(int r, int g, int b) {
    final rf = r / 255, gf = g / 255, bf = b / 255;
    final max = [rf, gf, bf].reduce((a, c) => a > c ? a : c);
    final min = [rf, gf, bf].reduce((a, c) => a < c ? a : c);
    final d = max - min;
    if (d == 0) return 0;
    double h;
    if (max == rf) {
      h = ((gf - bf) / d) % 6;
    } else if (max == gf) {
      h = (bf - rf) / d + 2;
    } else {
      h = (rf - gf) / d + 4;
    }
    return (h * 60 + 360) % 360;
  }

  static Animal _animal(String? emoji, int index) {
    const byEmoji = {
      '🐱': Animal.cat, '🐈': Animal.cat, '🐶': Animal.dog, '🐕': Animal.dog, '🐰': Animal.rabbit,
      '🐇': Animal.rabbit, '🐦': Animal.bird, '🐤': Animal.bird, '🦜': Animal.bird, '🦉': Animal.bird,
      '🦋': Animal.butterfly, '🐟': Animal.fish, '🐠': Animal.fish, '🐬': Animal.fish, '🐴': Animal.horse,
      '🦄': Animal.horse, '🐮': Animal.cow, '🐄': Animal.cow, '🐞': Animal.bug, '🐝': Animal.bug, '🐛': Animal.bug,
    };
    return byEmoji[emoji] ?? Animal.values[index % Animal.values.length];
  }

  static String _pictogram(String? emoji) {
    const byEmoji = {
      '🛏️': 'bed', '🛏': 'bed', '🦷': 'tooth', '🪥': 'tooth', '🧹': 'broom', '🗑️': 'trash', '🗑': 'trash',
      '♻️': 'recycle', '🍽️': 'dishes', '🍽': 'dishes', '🥣': 'dishes', '🍳': 'cooking', '👕': 'laundry',
      '🧺': 'laundry', '🛁': 'bath', '🚿': 'shower', '🚽': 'toilet', '🧽': 'spray', '🐕': 'pet', '🐶': 'pet',
      '🐈': 'pet', '🐱': 'pet', '🐾': 'pet', '🪴': 'plant', '🌱': 'plant', '🍂': 'leaf', '📚': 'book',
      '📖': 'book', '✏️': 'homework', '📝': 'homework', '🎒': 'backpack', '🎹': 'music', '🎵': 'music',
      '👟': 'shoes', '🚗': 'car', '📬': 'mail', '🔧': 'tools', '💊': 'pill',
    };
    return byEmoji[emoji] ?? 'check';
  }
}
