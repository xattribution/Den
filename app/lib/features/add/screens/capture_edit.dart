import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../state/capture_controller.dart';
import '../../../design/sheet.dart' show carryScope, carryTransition;
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../../../design/forms/forms.dart';
import '../../calendar/calendar.dart';

/// Issues a person settles by looking at an entry and saving it.
const Set<IssueKind> _settled = {IssueKind.needsDay, IssueKind.unknownPerson, IssueKind.guessed};

/// Opens the editor for one entry of a capture; saving puts the edit back in the tray, checked
/// again.
Future<void> editEntry(BuildContext context, CaptureController controller, DraftEntry entry) async {
  final result = await showModalBottomSheet<_Edit>(
    context: context,
    isScrollControlled: true,
    builder: carryScope(context, (_) => _EntryEditor(entry: entry)),
  );
  switch (result) {
    case null:
      return;
    case _Remove():
      controller.remove(entry.key);
    case _Save(:final entry):
      controller.edit(entry.withIssues([for (final i in entry.issues) if (!_settled.contains(i.kind)) i]));
  }
}

sealed class _Edit {}

class _Save extends _Edit {
  _Save(this.entry);
  final DraftEntry entry;
}

class _Remove extends _Edit {}

class _EntryEditor extends StatefulWidget {
  const _EntryEditor({required this.entry});
  final DraftEntry entry;

  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  late DraftEntry _e = widget.entry;
  late final _title = TextEditingController(text: widget.entry.title);
  late final _where = TextEditingController(text: switch (widget.entry) {
    DraftEvent(:final location) => location,
    _ => '',
  });
  late final _qty = TextEditingController(text: switch (widget.entry) {
    DraftItem(:final qty) => qty ?? '',
    _ => '',
  });
  late final _store = TextEditingController(text: switch (widget.entry) {
    DraftItem(:final store) => store ?? '',
    _ => '',
  });

  @override
  void dispose() {
    _title.dispose();
    _where.dispose();
    _qty.dispose();
    _store.dispose();
    super.dispose();
  }

  String? _clean(TextEditingController t) => t.text.trim().isEmpty ? null : t.text.trim();

  DraftEntry _built() {
    final title = _title.text.trim().isEmpty ? _e.title : _title.text.trim();
    return switch (_e) {
      DraftEvent e => e.copyWith(title: title, location: _where.text.trim()),
      DraftChore e => e.copyWith(title: title),
      DraftReminder e => e.copyWith(text: title),
      DraftItem e => e.copyWith(text: title, qty: _clean(_qty), store: _clean(_store)),
    };
  }

  Future<String?> _pickDay(String date) async {
    final f = context.app.formats;
    final initial = f.dateTime(date);
    final picked = await showDatePicker(
      context: context,
      builder: carryTransition(context),
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(initial.year - 1),
      lastDate: DateTime(initial.year + 3),
    );
    if (picked == null) return null;
    return '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
  }

  Future<String?> _pickTime(String? hhmm) async {
    final f = context.app.formats;
    final minutes = f.parseHhmm(hhmm) ?? 17 * 60;
    final picked = await showTimePicker(
      context: context,
      builder: carryTransition(context),
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
    );
    if (picked == null) return null;
    return f.hhmm(picked.hour * 60 + picked.minute);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final e = _e;
    final heading = switch (e) {
      DraftEvent() => 'Event',
      DraftChore() => 'Chore',
      DraftItem() => 'Item',
      DraftReminder() => 'Reminder',
    };

    Widget dayButton(String date, ValueChanged<String> set) => OutlinedButton(
          onPressed: () async {
            final d = await _pickDay(date);
            if (d != null) setState(() => set(d));
          },
          child: Text(f.shortWithYear(date, relativeTo: app.today)),
        );
    Widget timeButton(String? time, String empty, ValueChanged<String> set) => OutlinedButton(
          onPressed: () async {
            final t = await _pickTime(time);
            if (t != null) setState(() => set(t));
          },
          child: Text(time == null ? empty : f.clock(f.parseHhmm(time)!)),
        );
    Widget people({required List<String> chosen, required bool many, required ValueChanged<List<String>> set, String none = 'Everyone'}) =>
        Wrap(
          spacing: Sp.s,
          runSpacing: Sp.s,
          children: [
            AnyoneChip(label: none, selected: chosen.isEmpty, onTap: () => setState(() => set(const []))),
            for (final m in app.den.members)
              PersonChip(
                member: m,
                selected: chosen.contains(m.id),
                onTap: () => setState(() {
                  if (!many) {
                    set([m.id]);
                  } else {
                    set(chosen.contains(m.id) ? [...chosen.where((id) => id != m.id)] : [...chosen, m.id]);
                  }
                }),
              ),
          ],
        );

    final fields = <Widget>[
      FormBlock(
        top: 0,
        child: TextField(
          controller: _title,
          decoration: InputDecoration(labelText: e is DraftItem ? 'Item' : 'Title'),
          textCapitalization: TextCapitalization.sentences,
        ),
      ),
      ...switch (e) {
        DraftEvent() => [
            FormBlock(child: const FieldLabel('When', top: 0)),
            FormBlock(
              top: 0,
              child: Wrap(
                spacing: Sp.s,
                runSpacing: Sp.s,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  dayButton(e.date, (d) => _e = e.copyWith(date: d, endDate: e.endDate != null && e.endDate!.compareTo(d) <= 0 ? null : e.endDate)),
                  if (!e.allDay) ...[
                    timeButton(e.start, 'Start', (t) => _e = e.copyWith(start: t)),
                    Text('to', style: context.type.body(c.ink2)),
                    timeButton(e.end, 'End', (t) => _e = e.copyWith(end: t)),
                  ],
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('All day'),
              value: e.allDay,
              onChanged: (v) => setState(() => _e = v ? e.copyWith(start: null, end: null) : e.copyWith(start: '09:00', end: '10:00')),
            ),
            if (e.rrule != null)
              SwitchListTile(
                title: Text(describeRrule(e.rrule, f, startDate: e.date, weekStart: app.den.family?.weekStart ?? 0) ?? 'Repeats'),
                value: true,
                onChanged: (_) => setState(() => _e = e.copyWith(rrule: null)),
              ),
            FormBlock(child: const FieldLabel('Who', top: 0)),
            FormBlock(top: 0, child: people(chosen: e.people, many: true, set: (ids) => _e = e.copyWith(people: ids))),
            FormBlock(child: TextField(controller: _where, decoration: const InputDecoration(labelText: 'Where'))),
          ],
        DraftChore() => [
            FormBlock(child: const FieldLabel('Whose', top: 0)),
            FormBlock(
              top: 0,
              child: people(
                none: 'Anyone',
                chosen: switch (e.owner) {
                  OwnerMember(:final id) => [id],
                  OwnerRotation(:final ids) => ids,
                  OwnerAnyone() => const [],
                },
                many: false,
                set: (ids) => _e = e.copyWith(owner: ids.isEmpty ? const OwnerAnyone() : OwnerMember(ids.single)),
              ),
            ),
            FormBlock(child: FieldLabel(e.rrule == null ? 'Day' : 'Starts', top: 0)),
            FormBlock(
              top: 0,
              child: Wrap(spacing: Sp.s, children: [
                dayButton(e.date, (d) => _e = e.copyWith(date: d)),
                timeButton(e.dueTime, 'Due by', (t) => _e = e.copyWith(dueTime: t)),
              ]),
            ),
          ],
        DraftReminder() => [
            FormBlock(child: const FieldLabel('When', top: 0)),
            FormBlock(
              top: 0,
              child: Wrap(spacing: Sp.s, children: [
                dayButton(e.date, (d) => _e = e.copyWith(date: d)),
                timeButton(e.time, 'Time', (t) => _e = e.copyWith(time: t)),
              ]),
            ),
            FormBlock(child: const FieldLabel('Who', top: 0)),
            FormBlock(
              top: 0,
              child: people(
                none: 'Anyone',
                chosen: [?e.person],
                many: false,
                set: (ids) => _e = e.copyWith(person: ids.isEmpty ? null : ids.single),
              ),
            ),
          ],
        DraftItem() => [
            FormBlock(child: TextField(controller: _qty, decoration: const InputDecoration(labelText: 'Amount'))),
            FormBlock(child: TextField(controller: _store, decoration: const InputDecoration(labelText: 'Store'))),
            FormBlock(child: const FieldLabel('List', top: 0)),
            FormBlock(
              top: 0,
              child: Wrap(
                spacing: Sp.s,
                runSpacing: Sp.s,
                children: [
                  if (e.newList != null)
                    ChoiceTile.chip(label: '${e.newList!.title} (new)', selected: e.listId == null, onTap: () => setState(() => _e = e.copyWith(listId: null))),
                  for (final l in app.den.lists)
                    ChoiceTile.chip(
                      label: l.list.title,
                      selected: e.listId == l.list.id,
                      onTap: () => setState(() => _e = e.copyWith(listId: l.list.id, newList: e.newList)),
                    ),
                ],
              ),
            ),
          ],
      },
    ];

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: Sp.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.m),
                child: Text(heading, style: context.type.title(c.ink)),
              ),
              ...fields,
              Padding(
                padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xl, Sp.l, 0),
                child: Row(
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: c.bad),
                      onPressed: () => Navigator.of(context).pop(_Remove()),
                      child: const Text('Leave it out'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(_Save(_built())),
                      child: Text('Save ${heading.toLowerCase()}'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
