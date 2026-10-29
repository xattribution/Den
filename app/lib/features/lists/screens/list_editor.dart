import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/pictograms.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../state/list_actions.dart';
import '../words/list_words.dart';
import '../../../design/forms/forms.dart';
import '../state/lists_model.dart';

/// Adds a list or changes one: its name and kind, one optional date it's needed by, and whether
/// it's pinned; the event it's for and who sees it are under More options. `/lists/new`,
/// `/lists/:id/edit`.
class ListEditorScreen extends StatefulWidget {
  const ListEditorScreen({super.key, this.id});
  final String? id;

  @override
  State<ListEditorScreen> createState() => _ListEditorScreenState();
}

class _ListEditorScreenState extends State<ListEditorScreen> {
  final _title = TextEditingController();
  ListKind _kind = ListKind.shopping;
  ListLifecycle _lifecycle = ListLifecycle.running;
  String? _needBy;
  String? _event;
  bool _pinned = false;
  Audience _audience = Audience.everyone;
  bool _audienceChanged = false;
  bool _loaded = false;
  bool _saving = false;
  String? _titleError;
  String? _whenError;
  ListState? _existing;

  bool get _isNew => widget.id == null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final den = context.watch(listReads).den;
    final lv = widget.id == null ? null : den.list(widget.id!);
    _existing = lv;
    if (lv == null) {
      _pinned = den.lists.isEmpty;
      return;
    }
    final l = lv.list;
    _title.text = l.title;
    _kind = l.kind;
    _lifecycle = l.lifecycle;
    _needBy = l.needBy;
    _event = l.event;
    _pinned = l.pinned;
    _audience = l.audience;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final lists = context.listActions;
    final existing = _isNew ? null : DenScope.read(context).den.list(widget.id!);
    setState(() {
      _titleError = _title.text.trim().isEmpty ? 'Give the list a name.' : null;
      _whenError = switch (_lifecycle) {
        ListLifecycle.dated when _needBy == null => 'Choose the date it\'s needed by.',
        ListLifecycle.event when _event == null => 'Choose the event it\'s for.',
        _ => null,
      };
    });
    if (_titleError != null || _whenError != null) return;
    setState(() => _saving = true);
    final result = await perform(
      context,
      () => lists.save(
        existing,
        title: _title.text.trim(),
        kind: _kind,
        lifecycle: _lifecycle,
        needBy: _needBy,
        event: _event,
        pinned: _pinned,
        audience: _isNew || _audienceChanged ? _audience : null,
      ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result == null) return;
    final newId = _isNew ? ((result.data['list'] as Map?)?['id'] as String?) : null;
    if (newId != null) {
      context.go('/lists?list=$newId');
    } else if (context.canPop()) {
      context.pop();
    } else {
      context.go('/lists/${widget.id}');
    }
  }

  Future<void> _pickDate() async {
    final app = context.watch(listReads);
    final f = app.formats;
    final d = f.dateTime(_needBy ?? app.today);
    final picked = await showDayPicker(
      context,
      title: 'Needed by',
      initial: DateTime(d.year, d.month, d.day),
      first: DateTime(d.year - 1),
      last: DateTime(d.year + 3),
    );
    if (picked != null) {
      setState(() {
        _needBy = DateFormat('yyyy-MM-dd').format(picked);
        _whenError = null;
      });
    }
  }

  Future<void> _pickEvent() async {
    final app = context.watch(listReads);
    final f = app.formats;
    final start = f.startOf(app.today);
    final seen = <String>{};
    final upcoming = [
      for (final o in app.den.occurrences(start, start + const Duration(days: 120).inMilliseconds))
        if (seen.add(o.event.id)) o,
    ];
    final picked = await showChoiceSheet<String?>(
      context,
      title: 'Which event is it for?',
      value: _event,
      empty: 'Nothing on the calendar in the next four months.',
      choices: [
        for (final o in upcoming) Choice(o.event.id, o.title, detail: f.relative(f.localDate(o.start), app.today)),
      ],
    );
    if (picked != null) {
      setState(() {
        _event = picked;
        _whenError = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(listReads);
    final c = context.colors;
    final f = app.formats;
    if (!app.allows(DenAction.editLists)) {
      return Scaffold(
        appBar: AppBar(title: Text(_isNew ? 'New list' : 'Edit list')),
        body: const EmptyLine(
          message: 'Adding and changing lists needs a parent\'s OK. Ask a parent to turn it on for you.',
        ),
      );
    }
    if (!_isNew && _existing == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit list')),
        body: EmptyLine(
          message: 'This list was deleted, or it isn\'t shared with you.',
          actionLabel: 'Go to lists',
          onAction: () => context.go('/lists'),
        ),
      );
    }
    final event = _event == null ? null : app.den.event(_event!);
    final me = app.me;
    final space = _existing?.list.space;
    final privateOwner = space == null ? null : Space.memberOf(space);
    final othersPrivate = privateOwner != null && privateOwner != me?.id;
    final audiences = {
      Audience.everyone: 'Everyone',
      if (me?.isParent ?? false) Audience.parents: 'Parents',
      Audience.justMe: 'Just me',
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New list' : 'Edit list'),
        actions: [
          BarAction(
            child: FilledButton(onPressed: _saving ? null : _save, child: Text(_isNew ? 'Add list' : 'Save list')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.xxxl),
        children: [
          FormWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const FieldLabel('List', top: Sp.s),
                TextField(
                  controller: _title,
                  autofocus: _isNew,
                  textCapitalization: TextCapitalization.sentences,
                  style: context.type.body(c.ink),
                  decoration: const InputDecoration(hintText: 'Groceries'),
                  onChanged: (_) {
                    if (_titleError != null) setState(() => _titleError = null);
                  },
                ),
                FieldError(_titleError),
                const FieldLabel('Kind'),
                Wrap(
                  spacing: Sp.s,
                  runSpacing: Sp.s,
                  children: [
                    for (final k in ListKind.values)
                      TagChip(
                        icon: Pictograms.listKind(k),
                        label: kindWords(k),
                        selected: _kind == k,
                        onTap: () => setState(() => _kind = k),
                      ),
                  ],
                ),
                const FieldLabel(
                  'Needed by',
                  info: 'A list needed by a date shows on Today, and in Needs you the day before.',
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: PickerButton.outlined(
                    icon: PhosphorIconsRegular.calendarBlank,
                    label: _lifecycle == ListLifecycle.dated && _needBy != null
                        ? 'Needed by ${f.relative(_needBy!, app.today)}'
                        : 'Not by any date',
                    onTap: () async {
                      await _pickDate();
                      if (_needBy != null) setState(() => _lifecycle = ListLifecycle.dated);
                    },
                    onClear: _lifecycle == ListLifecycle.dated
                        ? () => setState(() {
                              _lifecycle = ListLifecycle.running;
                              _needBy = null;
                            })
                        : null,
                  ),
                ),
                FieldError(_whenError),
                const SizedBox(height: Sp.l),
                SwitchRow(
                  label: 'Pin to Today',
                  info: 'Pinned lists show on Today and first in Lists.',
                  value: _pinned,
                  onChanged: (v) => setState(() => _pinned = v),
                ),
                const SizedBox(height: Sp.l),
                // An event's list and who sees it, out of the way until asked for, and open from
                // the start when the list already uses one.
                MoreOptions(
                  initiallyOpen: _lifecycle == ListLifecycle.event || (_existing != null && _audience != Audience.everyone),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const FieldLabel('For an event', top: Sp.s, info: 'A list for an event shows on Today on the day of the event.'),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: PickerButton.outlined(
                          icon: PhosphorIconsRegular.calendarCheck,
                          label: _lifecycle != ListLifecycle.event
                              ? 'No event'
                              : event == null
                                  ? (_event == null ? 'Choose an event' : 'An event that was removed')
                                  : '${event.title}, ${f.relative(f.localDate(event.start), app.today)}',
                          onTap: () async {
                            await _pickEvent();
                            if (_event != null) setState(() => _lifecycle = ListLifecycle.event);
                          },
                          onClear: _lifecycle == ListLifecycle.event
                              ? () => setState(() {
                                    _lifecycle = _needBy == null ? ListLifecycle.running : ListLifecycle.dated;
                                    _event = null;
                                  })
                              : null,
                        ),
                      ),
                      const FieldLabel('Who sees it'),
                      if (othersPrivate && !_audienceChanged)
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Only ${app.den.member(privateOwner)?.name ?? 'one person'}',
                                style: context.text.body(c.ink),
                              ),
                            ),
                            TextButton(
                              onPressed: () => setState(() {
                                _audience = Audience.everyone;
                                _audienceChanged = true;
                              }),
                              child: const Text('Share with everyone'),
                            ),
                          ],
                        )
                      else
                        Align(
                          alignment: Alignment.centerLeft,
                          child: DenSegmented<Audience>(
                            options: audiences,
                            value: audiences.containsKey(_audience) ? _audience : Audience.everyone,
                            onChanged: (a) => setState(() {
                              _audience = a;
                              _audienceChanged = true;
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
                if (!_isNew) ...[
                  const SizedBox(height: Sp.xxl),
                  DestructiveButton(label: 'Delete list', onPressed: () => deleteListWithUndo(context, _existing!)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
