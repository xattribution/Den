import 'package:den_core/den_core.dart';

import '../context.dart';
import '../input.dart';
import '../recurrence.dart';
import '../resolve.dart';
import '../schema.dart';
import '../shapes.dart';
import '../spec.dart';
import '../times.dart';

/// The scope it takes to put back each kind of record.
const Map<String, Scope> _restoreScopes = {
  RecordType.event: Scope.calendar,
  RecordType.category: Scope.calendar,
  RecordType.chore: Scope.chores,
  RecordType.list: Scope.lists,
  RecordType.item: Scope.lists,
  RecordType.goal: Scope.points,
  RecordType.reward: Scope.points,
  RecordType.subscription: Scope.admin,
};

/// Taking back what an action did, or putting back something removed.
List<ActionSpec> undoActions() => [
      ActionSpec(
        name: 'undo',
        mcpName: 'undo',
        title: 'Undo',
        description: 'Takes back a change this connection made: give the "receipt" id a change returned, or nothing '
            'for the last one. Or puts back something removed: give its "type" and "id" (and for an event, the '
            '"occurrence" to put back one removed occurrence). Fields someone changed since are left as they are.',
        input: S.input({
          'receipt': S.string('The receipt id a change returned (default the last one).'),
          'type': S.string('To put back something removed: what kind it is.', oneOf: _restoreScopes.keys.toList()),
          'id': S.string('To put back something removed: its id.'),
          'ids': S.array(S.string('An id.'), 'To put back several removed things of one kind.', maxItems: 200),
          'occurrence': S.time('For an event: put back just this removed occurrence (its start or date).'),
        }),
        output: S.output({
          'undone': Out.strOrNull('The receipt taken back.'),
          'restored': Out.strings('Ids put back.'),
          'changes': Out.strings('The changes the undo made.'),
          'skipped': S.array(skippedShape, 'What was left as it is, and why.'),
        }),
        scopes: const {Scope.calendar, Scope.chores, Scope.lists, Scope.points},
        effect: Effect.destructive,
        engine: const {'undo', 'restore', 'restoreAll', 'restoreEvent'},
        example: const {},
        run: _undo,
      ),
    ];

Future<ActionResult> _undo(ActionContext c, ActionInput a) async {
  if (a.has('type')) return _restore(c, a);
  final runner = c.runner!;
  final receipt = a.has('receipt') ? runner.receipt(c, a.str('receipt')!) : runner.lastReceipt(c);
  if (receipt == null) {
    throw ActionError.notFound(a.has('receipt')
        ? 'There\'s no receipt "${a.str('receipt')}" from this connection to undo, or it was undone already. '
            'To put back something removed, give its "type" and "id".'
        : 'There\'s nothing from this connection to undo. To put back something removed, give its "type" and "id".');
  }
  final tool = runner.spec(receipt.tool);
  if (tool != null && !tool.scopes.any(c.has)) {
    throw ActionError.denied('Undoing ${receipt.tool} needs the scope it needed.');
  }
  final result = await c.den.undo(receipt.changes);
  runner.markUndone(receipt.id);
  final skipped = [
    for (final s in result.skipped)
      {'type': s.type, 'id': s.id, 'title': s.title, 'field': s.field, 'reason': s.reason},
  ];
  final text = [
    if (result.changes.isNotEmpty) 'Undid: ${receipt.summary}',
    if (result.changes.isEmpty) 'Nothing to undo for: ${receipt.summary}',
    for (final s in result.skipped) 'Left ${s.title}${s.field == null ? '' : '\'s ${s.field}'} as it is: ${s.reason}.',
  ].join(' ');
  return ActionResult(text, {'undone': receipt.id, 'restored': <String>[], 'changes': result.changes, 'skipped': skipped});
}

Future<ActionResult> _restore(ActionContext c, ActionInput a) async {
  final type = a.str('type')!;
  if (!c.has(_restoreScopes[type]!)) {
    throw ActionError.denied('Putting back a $type needs the "${_restoreScopes[type]!.name}" scope.');
  }
  final ids = [
    if (a.has('id')) a.str('id')!.trim(),
    for (final id in a.list('ids') ?? const []) '$id'.trim(),
  ];
  if (ids.isEmpty) throw ActionError('Give the "id" of what to put back.', field: 'id');
  if (type == RecordType.event && a.has('occurrence')) {
    if (ids.length != 1) throw ActionError('Put back one event\'s occurrence at a time.', field: 'ids');
    final event = c.den.event(ids.single);
    if (event == null) throw ActionError.notFound('That event isn\'t on the calendar; put it back without "occurrence".');
    final occurrence = _cancelledOccurrence(c, event, a.raw['occurrence']);
    await c.den.restoreEvent(event.id, scope: EditScope.one, occurrence: occurrence);
    return ActionResult('Put back ${event.title} on ${shortDate(dateIn(c.zone, occurrence))}.', {
      'undone': null,
      'restored': ['${event.id}@$occurrence'],
      'changes': <String>[],
      'skipped': <Object?>[],
    });
  }
  if (ids.length == 1) {
    await c.den.restore(type, ids.single);
  } else {
    await c.den.restoreAll(type, ids);
  }
  final titles = [for (final id in ids) _title(c, type, id) ?? id];
  return ActionResult('Put back ${joinNames(titles)}.', {
    'undone': null,
    'restored': ids,
    'changes': <String>[],
    'skipped': <Object?>[],
  });
}

String? _title(ActionContext c, String type, String id) => switch (type) {
      RecordType.event => c.den.event(id)?.title,
      RecordType.chore => c.den.chore(id)?.title,
      RecordType.list => c.den.list(id)?.list.title,
      RecordType.item => c.den.lists.expand((l) => l.items).where((i) => i.id == id).firstOrNull?.text,
      RecordType.category => c.den.category(id)?.name,
      RecordType.goal => c.den.goals.where((g) => g.id == id).firstOrNull?.title,
      RecordType.reward => c.den.rewards.where((r) => r.id == id).firstOrNull?.title,
      RecordType.subscription => c.den.subscription(id)?.label,
      _ => null,
    };

/// The original start of [event]'s removed occurrence at [value] (an exact start, or a date
/// when that day had one).
int _cancelledOccurrence(ActionContext c, Event event, Object? value) {
  final text = '$value'.trim();
  final exact = int.tryParse(text);
  if (exact != null) return exact;
  final at = toolInstant(value, c.zone, 'occurrence');
  if (isDate(text)) {
    final day = <int>[];
    for (final s in seriesStartsOf(event, c.zone, notBefore: at)) {
      if (s >= at + Duration.millisecondsPerDay) break;
      if (dateIn(c.zone, s) == text) day.add(s);
    }
    if (day.length == 1) return day.single;
  }
  if (isOccurrenceOf(event, c.zone, at)) return at;
  throw ActionError('${event.title} has no occurrence at "$value".', field: 'occurrence');
}
