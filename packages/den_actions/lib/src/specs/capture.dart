import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';

import '../context.dart';
import '../input.dart';
import '../schema.dart';
import '../shapes.dart';
import '../spec.dart';

/// Adding what a sentence, a message or a flyer's text says, read by den_capture: Siri
/// Shortcuts and voice assistants send what someone said.
List<ActionSpec> captureActions() => [
      ActionSpec(
        name: 'capture.add_from_text',
        mcpName: 'add_from_text',
        title: 'Add from what someone said or wrote',
        description: 'Reads a sentence ("soccer every Wednesday at 5 for Leo", "milk, eggs and bread", "remind me '
            'to call the dentist tomorrow at 9"), an email or the text of a flyer, and adds the events, chores, '
            'reminders and list items in it. What Den isn\'t sure of (a guessed time, something already there, '
            'a name nobody has) is left for a person to look at, unless "include_unsure" is true.',
        input: S.input({
          'text': S.string('What to read.', maxLength: 20000),
          'kind': S.string('Where it came from (default typed).', oneOf: ['typed', 'voice', 'email', 'message']),
          'list': S.string('Put the items it finds on this list (title or id).'),
          'include_unsure': S.boolean('Also add what Den isn\'t sure of.'),
        }, required: ['text']),
        output: S.output({
          'added': S.array(
            S.object({'type': Out.str('event, chore, list or item.'), 'id': Out.str('Its id.'), 'title': Out.str('What it is.')}),
            'What was added.',
          ),
          'left': S.array(
            S.object({'title': Out.str('What it is.'), 'reason': Out.str('Why it wasn\'t added.')}),
            'What wasn\'t added, and why.',
          ),
          'unclear': Out.strings('What Den saw but couldn\'t place.'),
          'reader': Out.str('Who read it.'),
        }),
        scopes: const {Scope.calendar, Scope.chores, Scope.lists},
        needs: const [DenAction.editEvents, DenAction.editChores, DenAction.editLists],
        effect: Effect.write,
        confirm: Confirm.client,
        engine: const {'addEvent', 'addChore', 'addList', 'addItem'},
        example: const {'text': 'Piano lesson for Maya next Tuesday at 4pm', 'include_unsure': true},
        run: _addFromText,
      ),
    ];

Scope _scopeOf(DraftEntry e) => switch (e) {
      DraftEvent() => Scope.calendar,
      DraftChore() || DraftReminder() => Scope.chores,
      DraftItem() => Scope.lists,
    };

Future<ActionResult> _addFromText(ActionContext c, ActionInput a) async {
  final text = a.str('text', required: true)!;
  final kind = CaptureKind.values.firstWhere((k) => k.name == (a.str('kind') ?? 'typed'));
  final context = CaptureContext.of(c.den);
  final input = CaptureInput(kind: kind, text: text);
  CaptureReader reader = const RulesReader();
  Map<String, Object?> wire;
  final hub = c.reader;
  if (hub != null && await hub.available()) {
    try {
      wire = await hub.read(ReadRequest(input, context));
      reader = hub;
    } on ReaderException {
      wire = await reader.read(ReadRequest(input, context));
    }
  } else {
    wire = await reader.read(ReadRequest(input, context));
  }
  var draft = checkDraft(c.den, draftFrom(wire, context, origin: CaptureOrigin(kind, reader: reader.info.historyName)));
  if (a.has('list')) {
    final list = c.list(a.str('list')!);
    draft = draft.withEntries([
      for (final e in draft.entries) e is DraftItem ? e.copyWith(listId: list.list.id, newList: null) : e,
    ]);
    draft = checkDraft(c.den, draft);
  }
  final unsure = a.flag('include_unsure') ?? false;
  final left = <Map<String, Object?>>[];
  final keys = <String>[];
  for (final e in draft.entries) {
    final scope = _scopeOf(e);
    final blocking = e.issues.where((i) => i.blocking).firstOrNull;
    if (!c.has(scope)) {
      left.add({'title': e.title, 'reason': 'This connection doesn\'t have the "${scope.name}" scope.'});
    } else if (blocking != null) {
      left.add({'title': e.title, 'reason': blocking.message});
    } else if (!e.ready && !unsure) {
      left.add({'title': e.title, 'reason': e.issues.where((i) => i.holds).map((i) => i.message).join('; ')});
    } else {
      keys.add(e.key);
    }
  }
  final receipt = keys.isEmpty ? null : await writeDraft(c.den, draft, keys: keys);
  for (final f in receipt?.failed.entries ?? const <MapEntry<String, String>>[]) {
    left.add({'title': draft.entry(f.key)?.title ?? '', 'reason': f.value});
  }
  final added = receipt?.added ?? const <Added>[];
  final said = [
    if (added.isNotEmpty) 'Added ${added.map((x) => x.title).join(', ')}.',
    if (added.isEmpty) 'Nothing was added.',
    for (final l in left) 'Not added: ${l['title']} (${l['reason']}).',
    if (draft.unclear.isNotEmpty) 'Den couldn\'t place: ${draft.unclear.join('; ')}.',
  ];
  return ActionResult(said.join(' '), {
    'added': [for (final x in added) {'type': x.type, 'id': x.id, 'title': x.title}],
    'left': left,
    'unclear': draft.unclear,
    'reader': reader.info.name,
  });
}
