import 'package:den_core/den_core.dart';

import '../context.dart';
import '../input.dart';
import '../resolve.dart';
import '../schema.dart';
import '../shapes.dart';
import '../spec.dart';
import '../times.dart';

final Map<String, Object?> _choreFields = {
  'title': S.string('What to do.', maxLength: 200),
  'owner': S.person('Whose chore it is, or "anyone".'),
  'rotation': S.people('People who take turns, in order (instead of owner).'),
  'rotate_every': S.string('How often the turn passes (default week).', oneOf: ['day', 'week']),
  'repeat': S.string('An RRULE such as FREQ=DAILY or FREQ=WEEKLY;BYDAY=MO,TH (default FREQ=DAILY).', maxLength: 500),
  'once': S.date('For a one-time chore, its date.'),
  'start': S.date('When a repeating chore starts (default today).'),
  'due_time': S.string('Due time, HH:mm (24-hour); empty for none.'),
  'points': S.integer('Stars for doing it.', min: 0, max: 1000),
  'icon': S.string('A pictogram for people who can\'t read yet.', oneOf: PictogramKeys.chores),
  'steps': S.array(
    S.object({
      'text': S.string('The step.', maxLength: 200),
      'owner': S.person('Who does this step.'),
      'points': S.integer('Stars for the step.', min: 0, max: 1000),
      'icon': S.string('A pictogram for the step.', oneOf: PictogramKeys.chores),
    }, required: ['text']),
    'Steps, in order.',
    maxItems: 30,
  ),
  'reminders': S.array(S.integer('Minutes before the due time.', min: 0, max: 40320), 'Reminders.', maxItems: 10),
  'notes': S.string('Notes.', maxLength: 5000),
};

/// Chore steps given as plain strings become `{text}`, as older clients send them.
Map<String, Object?> stepsAsObjects(Map<String, Object?> args) {
  final steps = args['steps'];
  if (steps is! List) return args;
  return {
    ...args,
    'steps': [for (final s in steps) s is String ? {'text': s} : s],
  };
}

/// The output of an action that answers with one chore on one day.
final Map<String, Object?> choreDayOutput = {'chore': choreDayShape};

/// Chore actions.
List<ActionSpec> choreActions() => [
      ActionSpec(
        name: 'chores.create',
        mcpName: 'create_chore',
        title: 'Add a chore',
        description: 'Adds a chore for a person, for anyone, or rotating between people.',
        input: S.input({
          ..._choreFields,
          'who_can_see': S.string('"everyone" (default), "parents", "just me", or a person\'s name.'),
        }, required: ['title']),
        output: S.output({
          'chore_id': Out.str('The new chore.'),
          'owner': S.dictionary('Who it belongs to.'),
          'schedule': S.dictionary('When it happens.'),
        }),
        scopes: const {Scope.chores},
        needs: const [DenAction.editChores],
        effect: Effect.write,
        engine: const {'addChore'},
        example: const {'title': 'Water the tomatoes', 'owner': 'Maya', 'repeat': 'FREQ=WEEKLY;BYDAY=SA', 'points': 2},
        prepare: stepsAsObjects,
        run: _create,
      ),
      ActionSpec(
        name: 'chores.update',
        mcpName: 'update_chore',
        title: 'Change a chore',
        description: 'Changes a chore. Fields left out stay as they are; "active": false pauses it.',
        input: S.input({
          'chore': S.string('The chore\'s title or id.'),
          ..._choreFields,
          'active': S.boolean('Whether it is scheduled.'),
        }, required: ['chore']),
        output: S.output({'ok': Out.flag('It worked.'), 'chore_id': Out.str('The chore.')}),
        scopes: const {Scope.chores},
        needs: const [DenAction.editChores],
        effect: Effect.destructive,
        idempotent: true,
        confirm: Confirm.client,
        engine: const {'updateChore'},
        example: const {'chore': 'Bring in the mail', 'due_time': '16:00'},
        prepare: stepsAsObjects,
        run: _update,
      ),
      ActionSpec(
        name: 'chores.complete',
        mcpName: 'complete_chore',
        title: 'Mark a chore done',
        description: 'Marks a chore done (or not done) on a day. Done also checks every step.',
        input: S.input({
          'chore': S.string('The chore\'s title or id.'),
          'date': S.date('The day (default today).'),
          'done': S.boolean('Done (default true) or not done.'),
          'person': S.person('Who did it (default this connection\'s person); also picks between chores with the same title.'),
        }, required: ['chore']),
        output: S.output(choreDayOutput),
        scopes: const {Scope.chores},
        needs: const [DenAction.completeOwnChore],
        effect: Effect.write,
        idempotent: true,
        engine: const {'setChoreDone', 'setChoreDoneBy'},
        example: const {'chore': 'Bring in the mail'},
        run: _complete,
      ),
      ActionSpec(
        name: 'chores.step',
        mcpName: 'check_step',
        title: 'Check a chore step',
        description: 'Checks or unchecks one step of a chore; checking the last step completes the chore.',
        input: S.input({
          'chore': S.string('The chore\'s title or id.'),
          'step': S.string('The step\'s text or id.'),
          'date': S.date('The day (default today).'),
          'checked': S.boolean('Checked (default true).'),
          'person': S.person('Who checked it (default this connection\'s person).'),
        }, required: ['chore', 'step']),
        output: S.output(choreDayOutput),
        scopes: const {Scope.chores},
        needs: const [DenAction.completeOwnChore],
        effect: Effect.write,
        idempotent: true,
        engine: const {'setStep', 'setStepBy'},
        example: const {'chore': 'Dishes', 'step': 'Clear the table'},
        run: _step,
      ),
      ActionSpec(
        name: 'chores.swap',
        mcpName: 'swap_chore',
        title: 'Swap a chore for a day',
        description: 'Hands a chore to someone else (or to anyone) for one day only.',
        input: S.input({
          'chore': S.string('The chore\'s title or id.'),
          'date': S.date('The day (default today).'),
          'to': S.person('Who takes it that day, or "anyone".'),
        }, required: ['chore', 'to']),
        output: S.output(choreDayOutput),
        scopes: const {Scope.chores},
        needs: const [DenAction.swapChore],
        effect: Effect.write,
        idempotent: true,
        engine: const {'swapForDay'},
        example: const {'chore': 'Feed the cat', 'to': 'Maya'},
        run: _swap,
      ),
    ];

ChoreOwner? _owner(ActionContext c, ActionInput a, String start) {
  final rotation = a.list('rotation');
  if (rotation != null && rotation.isNotEmpty) {
    return OwnerRotation(c.people.many(rotation, 'rotation'), a.str('rotate_every') ?? 'week', start);
  }
  final owner = a.str('owner');
  if (owner == null) return null;
  if (owner.trim().toLowerCase() == 'anyone') return const OwnerAnyone();
  return OwnerMember(c.people.one(owner));
}

ChoreSchedule? _schedule(ActionContext c, ActionInput a) {
  if (a.has('once')) return ChoreSchedule.once(toolDate(a.raw['once'], c.zone, 'once'));
  if (!a.has('repeat') && !a.has('start')) return null;
  final rule = (a.str('repeat') ?? 'FREQ=DAILY').trim();
  if (!RecurrenceRule.isValid(rule)) {
    throw ActionError('"$rule" isn\'t a repeat rule Den understands, such as FREQ=DAILY.', field: 'repeat');
  }
  return ChoreSchedule.repeating(rule, a.has('start') ? toolDate(a.raw['start'], c.zone, 'start') : c.today);
}

List<ChoreStep>? _steps(ActionContext c, ActionInput a) {
  final raw = a.objects('steps');
  if (raw == null) return null;
  return [
    for (final s in raw)
      ChoreStep(
        id: '',
        text: s['text']! as String,
        owner: s['owner'] == null ? null : c.people.one('${s['owner']}'),
        points: s['points'] as int? ?? 0,
        icon: s['icon'] as String?,
      ),
  ];
}

String? _due(ActionInput a) {
  final due = a.str('due_time')?.trim();
  if (due == null || due.isEmpty) return null;
  if (!isClockTime(due)) throw ActionError('"due_time" must be HH:mm, such as 07:30 or 19:00.', field: 'due_time');
  return due;
}

Future<ActionResult> _create(ActionContext c, ActionInput a) async {
  final title = a.str('title', required: true)!.trim();
  final schedule = _schedule(c, a) ?? ChoreSchedule.repeating('FREQ=DAILY', c.today);
  final owner = _owner(c, a, schedule.start ?? schedule.once ?? c.today) ?? const OwnerAnyone();
  final id = await c.den.addChore(
    title: title,
    owner: owner,
    schedule: schedule,
    icon: a.str('icon') ?? 'check',
    notes: a.str('notes') ?? '',
    dueTime: _due(a),
    points: a.integer('points') ?? 0,
    steps: _steps(c, a) ?? const [],
    reminders: a.ints('reminders') ?? const [],
    space: c.space(a.raw['who_can_see']),
  );
  final chore = c.den.chore(id)!;
  return ActionResult('Added the chore ${chore.title} [chore $id].', {'chore_id': id, 'owner': owner.toJson(), 'schedule': schedule.toJson()});
}

Future<ActionResult> _update(ActionContext c, ActionInput a) async {
  final chore = c.chore(a.str('chore', required: true)!);
  final schedule = _schedule(c, a);
  final owner = _owner(c, a, schedule?.start ?? schedule?.once ?? c.today);
  final steps = _steps(c, a);
  final patch = <String, Object?>{
    if (a.has('title')) 'title': a.str('title')!.trim(),
    if (a.present('notes')) 'notes': a.str('notes') ?? '',
    'owner': ?owner,
    'schedule': ?schedule,
    if (a.present('due_time')) 'dueTime': _due(a),
    if (a.has('points')) 'points': a.integer('points'),
    if (a.has('icon')) 'icon': a.str('icon'),
    'steps': ?steps,
    if (a.has('reminders')) 'reminders': a.ints('reminders'),
    if (a.has('active')) 'active': a.flag('active'),
  };
  if (patch.isEmpty) throw ActionError('Nothing to change: give a field such as title, owner or points.');
  await c.den.updateChore(chore.id, patch);
  return ActionResult('Changed the chore ${chore.title} [chore ${chore.id}].', {'ok': true, 'chore_id': chore.id});
}

String? _credit(ActionContext c, ActionInput a) => a.has('person') ? c.people.one(a.str('person')!) : c.member;

/// [chore] as it stands on [date], or an [ActionError] when it isn't on that day.
ChoreDay choreOnDay(ActionContext c, Chore chore, String date) {
  final day = c.den.choresOn(date).where((cd) => cd.chore.id == chore.id && cd.date == date).firstOrNull;
  if (day == null) throw ActionError.notFound('${chore.title} isn\'t on ${longDate(date)}.', type: 'chore', id: chore.id);
  return day;
}

Future<ActionResult> _complete(ActionContext c, ActionInput a) async {
  final date = a.has('date') ? toolDate(a.raw['date'], c.zone, 'date') : c.today;
  final who = _credit(c, a);
  final chore = c.chore(a.str('chore', required: true)!, owner: who, date: date);
  choreOnDay(c, chore, date);
  final done = a.flag('done') ?? true;
  if (who == c.member) {
    await c.den.setChoreDone(chore.id, date, done);
  } else {
    await c.den.setChoreDoneBy(chore.id, date, done, who);
  }
  final day = choreOnDay(c, chore, date);
  return ActionResult(
    '${chore.title} is ${day.done ? 'done' : 'not done'} on ${longDate(date)}${day.done && who != null ? ', by ${c.people.name(who)}' : ''}.',
    {'chore': c.wire.choreDay(day)},
  );
}

Future<ActionResult> _step(ActionContext c, ActionInput a) async {
  final date = a.has('date') ? toolDate(a.raw['date'], c.zone, 'date') : c.today;
  final who = _credit(c, a);
  final chore = c.chore(a.str('chore', required: true)!, owner: who, date: date);
  final step = pick(a.str('step', required: true)!, chore.steps, id: (s) => s.id, name: (s) => s.text, kind: 'step');
  choreOnDay(c, chore, date);
  final checked = a.flag('checked') ?? true;
  if (who == c.member) {
    await c.den.setStep(chore.id, date, step.id, checked);
  } else {
    await c.den.setStepBy(chore.id, date, step.id, checked, who);
  }
  final day = choreOnDay(c, chore, date);
  return ActionResult(
    '${checked ? 'Checked' : 'Unchecked'} "${step.text}" on ${chore.title}: ${day.stepsDone} of ${day.stepCount} steps${day.done ? ', chore done' : ''}.',
    {'chore': c.wire.choreDay(day)},
  );
}

Future<ActionResult> _swap(ActionContext c, ActionInput a) async {
  final date = a.has('date') ? toolDate(a.raw['date'], c.zone, 'date') : c.today;
  final chore = c.chore(a.str('chore', required: true)!, date: date);
  choreOnDay(c, chore, date);
  final to = a.str('to', required: true)!;
  final member = to.trim().toLowerCase() == 'anyone' ? null : c.people.one(to);
  await c.den.swapForDay(chore.id, date, member);
  final day = choreOnDay(c, chore, date);
  final whose = member == null ? 'for anyone' : '${c.people.name(member)}\'s';
  return ActionResult('${chore.title} on ${longDate(date)} is now $whose.', {'chore': c.wire.choreDay(day)});
}
