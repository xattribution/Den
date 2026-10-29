/// Output schemas of the objects [Wire] writes (docs/hub-api.md, "Shared objects").
library;

import 'schema.dart';

Map<String, Object?> _str(String d) => S.string(d);
Map<String, Object?> _strOrNull(String d) => S.string(d, nullable: true);
Map<String, Object?> _int(String d) => S.integer(d);
Map<String, Object?> _intOrNull(String d) => S.integer(d, nullable: true);
Map<String, Object?> _bool(String d) => S.boolean(d);
Map<String, Object?> _strings(String d) => S.array(S.string('An id or a value.'), d);

/// `{<name>, <name>_ms}`.
Map<String, Object?> _instant(String name, String d, {bool nullable = false}) => {
      name: S.string('$d, ISO 8601 in the family\'s zone.', nullable: nullable),
      '${name}_ms': S.integer('$d, UTC milliseconds.', nullable: nullable),
    };

/// Space and audience.
final Map<String, Object?> _space = {
  'space': _str('The space: f (everyone), p (parents) or m:<member id> (private).'),
  'audience': _str('everyone, parents or private.'),
};

final Map<String, Object?> _rides = {
  'rides': S.array(S.object({'leg': _str('to or from.'), 'driver': _strOrNull('Member id, or null when nobody is driving.')}), 'Ride legs.'),
};

final Map<String, Object?> _source = {
  'source': S.object({'kind': _str('manual, ics or device.'), 'label': _strOrNull('The calendar it came from.')}),
  'read_only': _bool('Comes from a subscribed calendar; change it there.'),
};

/// The family.
final Map<String, Object?> familyShape = S.object({
  'id': _str('Family id.'),
  'name': _str('Family name.'),
  'timezone': _str('IANA time zone.'),
  'week_start': _int('First day of the week, 0 Sunday to 6 Saturday.'),
  'points_enabled': _bool('Whether stars are on.'),
});

/// A person.
final Map<String, Object?> memberShape = S.object({
  'id': _str('Member id.'),
  'name': _str('Name.'),
  'role': _str('parent, adult, kid or guest.'),
  'tier': _strOrNull('For kids: preReader, little, big or teen.'),
  'marker': _str('Their color.'),
  'picture': _str('Their picture: a name from Den\'s picture pack (fox, whale, rocket...), "initial" for the first letter '
      'of their name, or "photo:<id>" when they have a photo.'),
  'animal': _str('The animal older versions of Den showed; picture replaces it.'),
  'birthday': _strOrNull('Birthday, YYYY-MM-DD.'),
  'until': _strOrNull('For a sitter: the last day they have access, YYYY-MM-DD.'),
  'grants': _strings('Extra permissions a kid has: events, chores, lists, points.'),
  'order': _int('Display order.'),
});

/// An event category.
final Map<String, Object?> categoryShape = S.object({'id': _str('Category id.'), 'name': _str('Name.'), 'icon': _str('Pictogram.')});

/// An event (a series, or a single event) as stored.
final Map<String, Object?> eventShape = S.object({
  'id': _str('Event id.'),
  'title': _str('Title.'),
  'notes': _str('Notes.'),
  'location': _str('Where.'),
  'category': _strOrNull('Category id.'),
  'all_day': _bool('A whole-day event.'),
  ..._instant('start', 'Start'),
  ..._instant('end', 'End (exclusive)'),
  'start_date': _strOrNull('First day of an all-day event.'),
  'end_date': _strOrNull('Day after the last day of an all-day event.'),
  'tz': _str('The time zone it repeats in.'),
  'rrule': _strOrNull('RFC 5545 repeat rule.'),
  'assignees': _strings('Member ids; empty means everyone.'),
  'reminders': S.array(_int('Minutes before.'), 'Reminders.'),
  ..._rides,
  'countdown': _bool('Shows a countdown.'),
  ..._source,
  ..._space,
});

/// One occurrence of an event.
final Map<String, Object?> occurrenceShape = S.object({
  'uid': _str('"<event_id>@<occurrence>".'),
  'event_id': _str('Event id.'),
  'occurrence': _int('The occurrence\'s original start, UTC ms, which edits address.'),
  'recurring': _bool('Part of a repeating event.'),
  'edited': _bool('Changed on its own.'),
  'title': _str('Title.'),
  'notes': _str('Notes.'),
  'location': _str('Where.'),
  'category': _strOrNull('Category id.'),
  'all_day': _bool('A whole-day event.'),
  ..._instant('start', 'Start'),
  ..._instant('end', 'End (exclusive)'),
  'start_date': _strOrNull('First day of an all-day event.'),
  'end_date': _strOrNull('Day after the last day of an all-day event.'),
  'tz': _str('The time zone it repeats in.'),
  'rrule': _strOrNull('RFC 5545 repeat rule.'),
  'assignees': _strings('Member ids; empty means everyone.'),
  'reminders': S.array(_int('Minutes before.'), 'Reminders.'),
  ..._rides,
  'countdown': _bool('Shows a countdown.'),
  ..._source,
  ..._space,
});

/// A chore on one date.
final Map<String, Object?> choreDayShape = S.object({
  'id': _str('Chore id.'),
  'completion_id': _str('"<chore id>@<date>".'),
  'date': _str('The date, YYYY-MM-DD.'),
  'title': _str('Title.'),
  'notes': _str('Notes.'),
  'icon': _str('Pictogram.'),
  'owner': _strOrNull('Whose it is that day; null is anyone.'),
  'owner_rule': S.dictionary('Who it belongs to: {kind: member, id}, {kind: anyone} or {kind: rotation, ids, every, anchor}.'),
  'swapped': _bool('Swapped for the day.'),
  'schedule': S.dictionary('{rrule, start} or {once}.'),
  'recurring': _bool('Repeats.'),
  'due_time': _strOrNull('HH:mm.'),
  ..._instant('due', 'Due', nullable: true),
  'done': _bool('Done.'),
  'done_by': _strOrNull('Who did it.'),
  'late': _bool('Past due and not done.'),
  'points': _int('Stars for the chore.'),
  'points_available': _int('Stars for the chore and its steps.'),
  'steps': S.array(
    S.object({
      'id': _str('Step id.'),
      'text': _str('The step.'),
      'owner': _strOrNull('Who does it.'),
      'points': _int('Stars.'),
      'checked': _bool('Checked.'),
      'checked_by': _strOrNull('Who checked it.'),
    }),
    'Steps.',
  ),
  'steps_done': _int('Steps checked.'),
  'step_count': _int('Steps.'),
  ..._space,
});

/// A chore as defined, not one day's view.
final Map<String, Object?> choreShape = S.object({
  'id': _str('Chore id.'),
  'title': _str('Title.'),
  'notes': _str('Notes.'),
  'icon': _str('Pictogram.'),
  'owner_rule': S.dictionary('Who it belongs to: {kind: member, id}, {kind: anyone} or {kind: rotation, ids, every, anchor}.'),
  'owner_text': _str('Who it belongs to, in words.'),
  'schedule': S.dictionary('{rrule, start} or {once}.'),
  'due_time': _strOrNull('HH:mm.'),
  'points': _int('Stars for the chore.'),
  'steps': S.array(
    S.object({'id': _str('Step id.'), 'text': _str('The step.'), 'owner': _strOrNull('Who does it.'), 'points': _int('Stars.')}),
    'Steps.',
  ),
  'reminders': S.array(_int('Minutes before the due time.'), 'Reminders.'),
  'active': _bool('Scheduled; false when paused.'),
  'recent': S.array(
    S.object({'date': _str('YYYY-MM-DD.'), 'done': _bool('Done.'), 'done_by': _strOrNull('Who did it.')}),
    'Recent completions, newest first.',
  ),
  ..._space,
});

/// An item on a list.
final Map<String, Object?> itemShape = S.object({
  'id': _str('Item id.'),
  'list': _str('List id.'),
  'text': _str('The item.'),
  'qty': _strOrNull('How many.'),
  'store': _strOrNull('Where to get it.'),
  'checked': _bool('Checked off.'),
  'checked_by': _strOrNull('Who checked it.'),
  'order': _str('Sort key.'),
  'to_groceries': _bool('On a meal plan: also on the groceries.'),
});

/// A list with its items.
final Map<String, Object?> listShape = S.object({
  'id': _str('List id.'),
  'title': _str('Title.'),
  'icon': _str('Pictogram.'),
  'kind': _str('shopping, checklist, packing or meal.'),
  'lifecycle': _str('running, dated or event.'),
  'need_by': _strOrNull('Needed by this date.'),
  'event': _strOrNull('The event it is for.'),
  'pinned': _bool('Shown on Today.'),
  'order': _str('Sort key.'),
  ..._space,
  'open': _int('Items not checked.'),
  'open_by_store': S.dictionary('Open items per store ("" for none).'),
  'items': S.array(itemShape, 'Items, in order.'),
});

/// A gap: something that needs someone.
final Map<String, Object?> gapShape = S.object({
  'kind': _str('no_driver, overlap or unowned.'),
  'message': _str('For people.'),
  'occurrences': _strings('Occurrence uids.'),
  'members': _strings('Member ids.'),
});

/// A reward.
final Map<String, Object?> rewardShape = S.object({
  'id': _str('Reward id.'),
  'title': _str('Title.'),
  'cost': _int('Stars.'),
  'icon': _str('Pictogram.'),
  'needs_approval': _bool('A parent approves requests.'),
  'active': _bool('Can be asked for.'),
});

/// A reward request.
final Map<String, Object?> redemptionShape = S.object({
  'id': _str('Request id.'),
  'reward': _str('Reward id.'),
  'member': _str('Who asked.'),
  'cost': _int('Stars.'),
  'status': _str('requested, approved or declined.'),
  ..._instant('requested', 'When it was asked for', nullable: true),
});

/// A goal with its standings.
final Map<String, Object?> goalShape = S.object({
  'id': _str('Goal id.'),
  'title': _str('Title.'),
  'mode': _str('target or race.'),
  'target': _int('Stars to reach.'),
  'members': S.array(S.string('Member id.'), 'Who takes part; null is every kid.', nullable: true),
  'start': _str('First day.'),
  'end': _strOrNull('Last day.'),
  'repeat': _str('none, weekly or monthly.'),
  'reward': _str('What reaching it earns.'),
  'window_start': _str('First day measured now.'),
  'window_end': _strOrNull('Day after the last measured.'),
  'winner': _strOrNull('For races: who got there first.'),
  'standings': S.array(
    S.object({'member': _str('Member id.'), 'earned': _int('Stars earned.'), ..._instant('reached', 'When they reached it', nullable: true)}),
    'Standings.',
  ),
});

/// The points summary.
final Map<String, Object?> pointsShape = {
  'enabled': _bool('Whether stars are on.'),
  'totals': S.dictionary('Member id to balance.'),
  'goals': S.array(goalShape, 'Goals.'),
  'recent': S.array(
    S.object({
      'member': _str('Member id.'),
      'delta': _int('Stars.'),
      'reason': _str('Why.'),
      'source': _str('chore, step, adjustment or reward.'),
      'ref': _strOrNull('What it came from.'),
      ..._instant('when', 'When'),
    }),
    'Recent points, newest first.',
  ),
  'rewards': S.array(rewardShape, 'Rewards.'),
  'pending': S.array(redemptionShape, 'Requests waiting for a parent.'),
};

/// One history entry.
final Map<String, Object?> historyShape = S.object({
  ..._instant('when', 'When'),
  'hlc': _str('Clock.'),
  'actor': _strOrNull('Member id.'),
  'actor_name': _str('Who.'),
  'device': _str('Device id.'),
  'device_name': _str('Device.'),
  'via': _strOrNull('The connection that made it through the hub.'),
  'when_local': _strOrNull('When, in the zone asked for or where the person lives, if not the family\'s.'),
  'type': _str('Record type.'),
  'rid': _str('Record id.'),
  'title': _str('What people call it.'),
  'verb': _str('added, changed, removed, ...'),
  'space': _str('Space.'),
  'diffs': S.array(S.object({'field': _str('Field.'), 'before': S.any('Before.'), 'after': S.any('After.')}), 'What changed.'),
});

/// One search result.
final Map<String, Object?> searchHitShape = S.object({
  'type': _str('Record type.'),
  'id': _str('Record id.'),
  'title': _str('Title.'),
  'detail': _strOrNull('More.'),
  ..._instant('when', 'When', nullable: true),
});

/// A subscribed calendar.
final Map<String, Object?> feedShape = S.object({
  'id': _str('Feed id.'),
  'url': _str('The ICS address.'),
  'label': _str('Name.'),
  'category': _strOrNull('Category id for its events.'),
  'assignee': _strOrNull('Member id its events are for.'),
  ..._space,
  'include': _strings('Only events with these words.'),
  'exclude': _strings('Not events with these words.'),
  'skip_all_day': _bool('Leaves out all-day events.'),
  'status': _str('How the last fetch went.'),
});

/// What an undo left alone.
final Map<String, Object?> skippedShape = S.object({
  'type': _str('Record type.'),
  'id': _str('Record id.'),
  'title': _str('What people call it.'),
  'field': _strOrNull('The field left as it is.'),
  'reason': _str('Why.'),
});

/// Output helpers shared by specs.
abstract final class Out {
  /// `{ok: true}`.
  static final Map<String, Object?> ok = {'ok': _bool('It worked.')};

  /// A string.
  static Map<String, Object?> str(String d) => _str(d);

  /// A string or null.
  static Map<String, Object?> strOrNull(String d) => _strOrNull(d);

  /// An integer.
  static Map<String, Object?> integer(String d) => _int(d);

  /// An integer or null.
  static Map<String, Object?> intOrNull(String d) => _intOrNull(d);

  /// A flag.
  static Map<String, Object?> flag(String d) => _bool(d);

  /// A list of strings.
  static Map<String, Object?> strings(String d) => _strings(d);
}
