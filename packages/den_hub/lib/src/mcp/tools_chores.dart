import 'package:den_core/den_core.dart';

import '../times.dart';
import 'resolve.dart';
import 'tool.dart';

final Map<String, Object?> _choreFields = {
  'title': sString('What to do.'),
  'owner': sPerson('Whose chore it is, or "anyone".'),
  'rotation': sList(sString('A name or member id.'), 'People who take turns, in order (instead of owner).'),
  'rotate_every': sString('How often the turn passes (default week).', oneOf: ['day', 'week']),
  'repeat': sString('An RRULE such as FREQ=DAILY or FREQ=WEEKLY;BYDAY=MO,TH (default FREQ=DAILY).'),
  'once': sTime('For a one-time chore, its date.'),
  'start': sTime('When a repeating chore starts (default today).'),
  'due_time': sString('Due time, HH:mm (24-hour).'),
  'points': sInt('Stars for doing it.', min: 0, max: 1000),
  'steps': sList({
    'type': 'object',
    'properties': {
      'text': sString('The step.'),
      'owner': sPerson('Who does this step.'),
      'points': sInt('Stars for the step.', min: 0, max: 1000),
    },
    'required': ['text'],
  }, 'Steps, in order.', max: 30),
  'reminders': sList(sInt('Minutes before the due time.', min: 0, max: 40320), 'Reminders.', max: 10),
  'notes': sString('Notes.'),
};

/// Chore tools.
List<Tool> choreTools() => [
      Tool(
        name: 'create_chore',
        title: 'Add a chore',
        description: 'Adds a chore for a person, for anyone, or rotating between people.',
        properties: {..._choreFields, 'who_can_see': sString('"everyone" (default), "parents", "just me", or a person\'s name.')},
        required: ['title'],
        scope: Scope.chores,
        readOnly: false,
        run: _create,
      ),
      Tool(
        name: 'update_chore',
        title: 'Change a chore',
        description: 'Changes a chore. Fields left out stay as they are; "active": false pauses it.',
        properties: {'chore': sString('The chore\'s title or id.'), ..._choreFields, 'active': sBool('Whether it is scheduled.')},
        required: ['chore'],
        scope: Scope.chores,
        readOnly: false,
        destructive: true,
        idempotent: true,
        run: _update,
      ),
      Tool(
        name: 'complete_chore',
        title: 'Mark a chore done',
        description: 'Marks a chore done (or not done) on a day. Done also checks every step.',
        properties: {
          'chore': sString('The chore\'s title or id.'),
          'date': sTime('The day (default today).'),
          'done': sBool('Done (default true) or not done.'),
          'person': sPerson('Who did it (default this connection\'s person); also picks between chores with the same title.'),
        },
        required: ['chore'],
        scope: Scope.chores,
        readOnly: false,
        idempotent: true,
        run: _complete,
      ),
      Tool(
        name: 'check_step',
        title: 'Check a chore step',
        description: 'Checks or unchecks one step of a chore; checking the last step completes the chore.',
        properties: {
          'chore': sString('The chore\'s title or id.'),
          'step': sString('The step\'s text or id.'),
          'date': sTime('The day (default today).'),
          'checked': sBool('Checked (default true).'),
          'person': sPerson('Who checked it (default this connection\'s person).'),
        },
        required: ['chore', 'step'],
        scope: Scope.chores,
        readOnly: false,
        idempotent: true,
        run: _step,
      ),
      Tool(
        name: 'swap_chore',
        title: 'Swap a chore for a day',
        description: 'Hands a chore to someone else (or to anyone) for one day only.',
        properties: {
          'chore': sString('The chore\'s title or id.'),
          'date': sTime('The day (default today).'),
          'to': sPerson('Who takes it that day, or "anyone".'),
        },
        required: ['chore', 'to'],
        scope: Scope.chores,
        readOnly: false,
        idempotent: true,
        run: _swap,
      ),
    ];

ChoreOwner? _owner(ToolContext c, Args a, String start) {
  final rotation = a.list('rotation');
  if (rotation != null && rotation.isNotEmpty) {
    final every = a.str('rotate_every') ?? 'week';
    if (every != 'day' && every != 'week') throw ToolError('"rotate_every" must be day or week.');
    return OwnerRotation(c.people.many(rotation, 'rotation'), every, start);
  }
  final owner = a.str('owner');
  if (owner == null) return null;
  if (owner.trim().toLowerCase() == 'anyone') return const OwnerAnyone();
  return OwnerMember(c.people.one(owner));
}

ChoreSchedule? _schedule(ToolContext c, Args a) {
  if (a.has('once')) return ChoreSchedule.once(toolDate(a.raw['once'], c.zone, 'once'));
  if (!a.has('repeat') && !a.has('start')) return null;
  final rule = (a.str('repeat') ?? 'FREQ=DAILY').trim();
  if (!RecurrenceRule.isValid(rule)) throw ToolError('"$rule" isn\'t a repeat rule Den understands, such as FREQ=DAILY.');
  return ChoreSchedule.repeating(rule, a.has('start') ? toolDate(a.raw['start'], c.zone, 'start') : c.today);
}

List<ChoreStep>? _steps(ToolContext c, Args a) {
  final raw = a.list('steps');
  if (raw == null) return null;
  return [
    for (final s in raw)
      if (s is String)
        ChoreStep(id: '', text: s)
      else if (s is Map && s['text'] is String)
        ChoreStep(
          id: '',
          text: s['text'] as String,
          owner: s['owner'] == null ? null : c.people.one('${s['owner']}'),
          points: s['points'] is int ? s['points'] as int : 0,
        )
      else
        throw ToolError('Each step is text, or {"text", "owner", "points"}.'),
  ];
}

String? _due(Args a) {
  final due = a.str('due_time');
  if (due == null || due.isEmpty) return null;
  if (!isClockTime(due)) throw ToolError('"due_time" must be HH:mm, such as 07:30 or 19:00.');
  return due;
}

Future<ToolResult> _create(ToolContext c, Args a) async {
  final title = a.str('title', required: true, max: 200)!.trim();
  final schedule = _schedule(c, a) ?? ChoreSchedule.repeating('FREQ=DAILY', c.today);
  final owner = _owner(c, a, schedule.start ?? schedule.once ?? c.today) ?? const OwnerAnyone();
  final id = await c.den.addChore(
    title: title,
    owner: owner,
    schedule: schedule,
    notes: a.str('notes') ?? '',
    dueTime: _due(a),
    points: a.integer('points', min: 0, max: 1000) ?? 0,
    steps: _steps(c, a) ?? const [],
    reminders: [for (final r in a.list('reminders') ?? const []) if (r is int) r],
    space: c.space(a.raw['who_can_see']),
  );
  final chore = c.den.chore(id)!;
  return ToolResult('Added the chore ${chore.title} [chore $id].', {'chore_id': id, 'owner': owner.toJson(), 'schedule': schedule.toJson()});
}

Future<ToolResult> _update(ToolContext c, Args a) async {
  final chore = c.chore(a.str('chore', required: true)!);
  final schedule = _schedule(c, a);
  final owner = _owner(c, a, schedule?.start ?? schedule?.once ?? c.today);
  final steps = _steps(c, a);
  final patch = <String, Object?>{
    if (a.has('title')) 'title': a.str('title', max: 200)!.trim(),
    if (a.has('notes')) 'notes': a.str('notes'),
    'owner': ?owner,
    'schedule': ?schedule,
    if (a.raw.containsKey('due_time')) 'dueTime': _due(a),
    if (a.has('points')) 'points': a.integer('points', min: 0, max: 1000),
    'steps': ?steps,
    if (a.has('reminders')) 'reminders': [for (final r in a.list('reminders')!) if (r is int) r],
    if (a.has('active')) 'active': a.flag('active'),
  };
  if (patch.isEmpty) throw ToolError('Nothing to change: give a field such as title, owner or points.');
  await c.den.updateChore(chore.id, patch);
  return ToolResult('Changed the chore ${chore.title} [chore ${chore.id}].', {'ok': true, 'chore_id': chore.id});
}

String? _credit(ToolContext c, Args a) => a.has('person') ? c.people.one(a.str('person')!) : c.access.member;

ChoreDay _day(ToolContext c, Chore chore, String date) {
  final day = c.den.choresOn(date).where((cd) => cd.chore.id == chore.id && cd.date == date).firstOrNull;
  if (day == null) throw ToolError('${chore.title} isn\'t on ${longDate(date)}.');
  return day;
}

Future<ToolResult> _complete(ToolContext c, Args a) async {
  final date = a.has('date') ? toolDate(a.raw['date'], c.zone, 'date') : c.today;
  final who = _credit(c, a);
  final chore = c.chore(a.str('chore', required: true)!, owner: who, date: date);
  _day(c, chore, date);
  final done = a.flag('done') ?? true;
  if (who == c.access.member) {
    await c.den.setChoreDone(chore.id, date, done);
  } else {
    await c.den.setChoreDoneBy(chore.id, date, done, who);
  }
  final day = _day(c, chore, date);
  return ToolResult(
    '${chore.title} is ${day.done ? 'done' : 'not done'} on ${longDate(date)}${day.done && who != null ? ', by ${c.people.name(who)}' : ''}.',
    {'chore': c.wire.choreDay(day)},
  );
}

Future<ToolResult> _step(ToolContext c, Args a) async {
  final date = a.has('date') ? toolDate(a.raw['date'], c.zone, 'date') : c.today;
  final who = _credit(c, a);
  final chore = c.chore(a.str('chore', required: true)!, owner: who, date: date);
  final step = pick(a.str('step', required: true)!, chore.steps, id: (s) => s.id, name: (s) => s.text, kind: 'step');
  _day(c, chore, date);
  final checked = a.flag('checked') ?? true;
  if (who == c.access.member) {
    await c.den.setStep(chore.id, date, step.id, checked);
  } else {
    await c.den.setStepBy(chore.id, date, step.id, checked, who);
  }
  final day = _day(c, chore, date);
  return ToolResult(
    '${checked ? 'Checked' : 'Unchecked'} "${step.text}" on ${chore.title}: ${day.stepsDone} of ${day.stepCount} steps${day.done ? ', chore done' : ''}.',
    {'chore': c.wire.choreDay(day)},
  );
}

Future<ToolResult> _swap(ToolContext c, Args a) async {
  final date = a.has('date') ? toolDate(a.raw['date'], c.zone, 'date') : c.today;
  final chore = c.chore(a.str('chore', required: true)!, date: date);
  _day(c, chore, date);
  final to = a.str('to', required: true)!;
  final member = to.trim().toLowerCase() == 'anyone' ? null : c.people.one(to);
  await c.den.swapForDay(chore.id, date, member);
  final day = _day(c, chore, date);
  final whose = member == null ? 'for anyone' : '${c.people.name(member)}\'s';
  return ToolResult('${chore.title} on ${longDate(date)} is now $whose.',
      {'chore': c.wire.choreDay(day)});
}
