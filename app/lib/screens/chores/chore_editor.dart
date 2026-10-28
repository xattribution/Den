import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/parts/home_form.dart';
import '../../design/pictograms.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import 'chore_words.dart';
import '../../design/parts/home_pictograms.dart';

enum _OwnerKind { person, anyone, turns }

class _StepDraft {
  _StepDraft({required this.id, String text = '', this.owner, this.points = 0})
    : text = TextEditingController(text: text);
  final String id;
  final TextEditingController text;
  String? owner;
  int points;
}

/// Adds or edits a chore: picture, name, who does it (a person, anyone, or turns), when it
/// repeats, due time, points, steps, reminders and who sees it. `/chore/new`, `/chore/:id/edit`.
class ChoreEditorScreen extends StatefulWidget {
  const ChoreEditorScreen({super.key, this.id});

  /// Null for a new chore.
  final String? id;

  @override
  State<ChoreEditorScreen> createState() => _ChoreEditorScreenState();
}

class _ChoreEditorScreenState extends State<ChoreEditorScreen> {
  final _title = TextEditingController();
  final _notes = TextEditingController();
  String _icon = 'check';
  bool _iconChosen = false;
  _OwnerKind _kind = _OwnerKind.person;
  String? _person;
  List<String> _turns = [];
  String _every = 'week';
  String? _anchor;
  ScheduleSpec? _spec;
  TimeOfDay? _due;
  int _points = 1;
  final List<_StepDraft> _steps = [];
  Set<int> _reminders = {};
  Audience _audience = Audience.everyone;
  bool _audienceChanged = false;
  bool _loaded = false;
  bool _saving = false;
  String? _titleError;
  String? _ownerError;
  String? _whenError;
  Chore? _existing;

  bool get _isNew => widget.id == null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final app = context.app;
    final today = app.today;
    final chore = widget.id == null ? null : app.den.chore(widget.id!);
    _existing = chore;
    if (chore == null) {
      _spec = ScheduleSpec(repeat: Repeat.daily, start: today, days: {app.formats.dateTime(today).weekday});
      final me = app.me;
      if (me != null && me.isKid) _person = me.id;
      // Only someone who may set prices gives a new chore points; for anyone else it's worth none.
      _points = (app.den.family?.pointsEnabled ?? true) && app.allows(DenAction.managePoints) ? 1 : 0;
      _title.addListener(_suggestIcon);
      return;
    }
    _title.text = chore.title;
    _notes.text = chore.notes;
    _icon = chore.icon;
    _iconChosen = true;
    switch (chore.owner) {
      case OwnerMember(:final id):
        _kind = _OwnerKind.person;
        _person = id;
      case OwnerAnyone():
        _kind = _OwnerKind.anyone;
      case OwnerRotation(:final ids, :final every, :final anchor):
        _kind = _OwnerKind.turns;
        _turns = [...ids];
        _every = every;
        _anchor = anchor;
    }
    _spec = ScheduleSpec.fromSchedule(chore.schedule, today: today);
    if (_spec!.days.isEmpty) _spec!.days = {app.formats.dateTime(_spec!.start).weekday};
    if (chore.dueTime != null) {
      final p = chore.dueTime!.split(':');
      _due = TimeOfDay(hour: int.tryParse(p.first) ?? 0, minute: p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0);
    }
    _points = chore.points;
    for (final s in chore.steps) {
      _steps.add(_StepDraft(id: s.id, text: s.text, owner: s.owner, points: s.points));
    }
    _reminders = {...chore.reminders};
    _audience = chore.audience;
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    for (final s in _steps) {
      s.text.dispose();
    }
    super.dispose();
  }

  static const _keywords = <String, String>{
    'dish': 'dishes',
    'bed': 'bed',
    'teeth': 'tooth',
    'tooth': 'tooth',
    'sweep': 'broom',
    'vacuum': 'broom',
    'floor': 'broom',
    'mop': 'broom',
    'trash': 'trash',
    'garbage': 'trash',
    'recycl': 'recycle',
    'cook': 'cooking',
    'dinner': 'cooking',
    'lunch': 'cooking',
    'laundry': 'laundry',
    'fold': 'hanger',
    'clothes': 'hanger',
    'bath': 'bath',
    'shower': 'shower',
    'toilet': 'toilet',
    'clean': 'spray',
    'wipe': 'spray',
    'dust': 'spray',
    'dog': 'pet',
    'cat': 'pet',
    'pet': 'pet',
    'feed': 'pet',
    'plant': 'plant',
    'water': 'plant',
    'yard': 'leaf',
    'rake': 'leaf',
    'garden': 'leaf',
    'read': 'book',
    'homework': 'homework',
    'study': 'homework',
    'backpack': 'backpack',
    'practice': 'music',
    'piano': 'music',
    'shoes': 'shoes',
    'car': 'car',
    'mail': 'mail',
    'fix': 'tools',
    'medicine': 'pill',
    'vitamin': 'pill',
  };

  void _suggestIcon() {
    if (_iconChosen) return;
    final t = _title.text.toLowerCase();
    final hit = _keywords.entries.where((e) => t.contains(e.key)).firstOrNull;
    final next = hit?.value ?? 'check';
    if (next != _icon) setState(() => _icon = next);
  }

  String _weekStartOf(AppState app, String date) {
    final f = app.formats;
    final weekday = f.dateTime(date).weekday % 7;
    final start = app.den.family?.weekStart ?? 0;
    return f.addDays(date, -((weekday - start + 7) % 7));
  }

  ChoreOwner _owner(AppState app) => switch (_kind) {
    _OwnerKind.person => OwnerMember(_person!),
    _OwnerKind.anyone => const OwnerAnyone(),
    _OwnerKind.turns => OwnerRotation(
      _turns,
      _every,
      _sameRotation() && _anchor != null ? _anchor! : (_every == 'week' ? _weekStartOf(app, app.today) : app.today),
    ),
  };

  bool _sameRotation() {
    final old = _existing?.owner;
    if (old is! OwnerRotation) return false;
    return old.every == _every && old.ids.join(',') == _turns.join(',');
  }

  Future<void> _save() async {
    final app = context.app;
    final den = app.den;
    final spec = _spec!;
    setState(() {
      _titleError = _title.text.trim().isEmpty ? 'Give the chore a name.' : null;
      _ownerError = switch (_kind) {
        _OwnerKind.person when _person == null => 'Choose who does it.',
        _OwnerKind.turns when _turns.length < 2 => 'Choose two or more people to take turns.',
        _ => null,
      };
      _whenError = (spec.repeat == Repeat.days || spec.repeat == Repeat.everyWeeks) && spec.days.isEmpty
          ? 'Choose at least one day.'
          : null;
    });
    if (_titleError != null || _ownerError != null || _whenError != null) return;

    final owner = _owner(app);
    final schedule = spec.toSchedule();
    final due = _due == null
        ? null
        : '${_due!.hour.toString().padLeft(2, '0')}:${_due!.minute.toString().padLeft(2, '0')}';
    final steps = [
      for (final s in _steps)
        if (s.text.text.trim().isNotEmpty)
          ChoreStep(id: s.id, text: s.text.text.trim(), owner: s.owner, points: s.points),
    ];
    final reminders = due == null ? <int>[] : (_reminders.toList()..sort());
    setState(() => _saving = true);
    final ok = await attempt(context, () async {
      if (_isNew) {
        await den.addChore(
          title: _title.text.trim(),
          owner: owner,
          schedule: schedule,
          icon: _icon,
          notes: _notes.text.trim(),
          dueTime: due,
          points: _points,
          steps: steps,
          reminders: reminders,
          audience: _audience,
        );
      } else {
        await den.updateChore(widget.id!, {
          'title': _title.text.trim(),
          'icon': _icon,
          'owner': owner.toJson(),
          'schedule': schedule.toJson(),
          'dueTime': due,
          'points': _points,
          'steps': [for (final s in steps) s.toJson()],
          'reminders': reminders,
          'notes': _notes.text.trim(),
          if (_audienceChanged) 'audience': _audience.name,
        });
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/chores');
    }
  }

  Future<void> _pickDate(String initial, ValueChanged<String> onPicked) async {
    final f = context.app.formats;
    final d = f.dateTime(initial);
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(d.year, d.month, d.day),
      firstDate: DateTime(d.year - 1),
      lastDate: DateTime(d.year + 3),
    );
    if (picked != null) onPicked(DateFormat('yyyy-MM-dd').format(picked));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    if (!app.allows(DenAction.editChores)) {
      return Scaffold(
        appBar: AppBar(title: Text(_isNew ? 'New chore' : 'Edit chore')),
        body: const EmptyLine(
          message: 'Adding and changing chores needs a parent\'s OK. Ask a parent to turn it on for you.',
        ),
      );
    }
    if (!_isNew && _existing == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit chore')),
        body: EmptyLine(
          message: 'This chore was deleted, or it isn\'t shared with you.',
          actionLabel: 'Go to chores',
          onAction: () => context.go('/chores'),
        ),
      );
    }
    // What a chore or step is worth is set only by whoever may manage points.
    final pointsOn = (app.den.family?.pointsEnabled ?? true) && app.allows(DenAction.managePoints);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New chore' : 'Edit chore'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: Sp.s),
            child: FilledButton(onPressed: _saving ? null : _save, child: Text(_isNew ? 'Add chore' : 'Save chore')),
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
                const FieldLabel('Chore', top: Sp.s),
                TextField(
                  controller: _title,
                  autofocus: _isNew,
                  textCapitalization: TextCapitalization.sentences,
                  style: context.type.body(c.ink),
                  decoration: const InputDecoration(hintText: 'Dishes'),
                  onChanged: (_) {
                    if (_titleError != null) setState(() => _titleError = null);
                  },
                ),
                FieldError(_titleError),
                const FieldLabel('Picture'),
                PictogramGrid(
                  icons: HomePictograms.withCurrent(Pictograms.chores, _icon, HomePictograms.chore(_icon)),
                  value: _icon,
                  onChanged: (k) => setState(() {
                    _icon = k;
                    _iconChosen = true;
                  }),
                ),
                ..._whoSection(app),
                ..._whenSection(app),
                FieldLabel(
                  'Due by',
                  info: _due == null ? 'With a due time, a chore shows as late once it passes.' : null,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ValueButton(
                    icon: PhosphorIconsRegular.clock,
                    label: _due == null ? 'Any time that day' : _due!.format(context),
                    onPressed: () async {
                      final t = await showTimePicker(
                        context: context,
                        initialTime: _due ?? const TimeOfDay(hour: 18, minute: 0),
                      );
                      if (t != null) setState(() => _due = t);
                    },
                    onClear: _due == null ? null : () => setState(() => _due = null),
                  ),
                ),
                if (_due != null) ...[
                  const FieldLabel('Reminders', info: 'Reminders count back from the due time.'),
                  Wrap(
                    spacing: Sp.s,
                    children: [
                      for (final entry in reminderChoices.entries)
                        InkChip(
                          label: entry.value,
                          selected: _reminders.contains(entry.key),
                          onTap: () => setState(() {
                            if (!_reminders.remove(entry.key)) _reminders.add(entry.key);
                          }),
                        ),
                    ],
                  ),
                ],
                if (pointsOn) ...[
                  const FieldLabel('Points', info: 'Points go to whoever the chore belongs to that day.'),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: NumberStepper(
                      label: 'Points',
                      value: _points,
                      max: 100,
                      onChanged: (v) => setState(() => _points = v),
                      suffix: const Star(size: 18),
                    ),
                  ),
                ],
                ..._stepsSection(app, pointsOn),
                ..._audienceSection(app),
                const FieldLabel('Notes'),
                TextField(
                  controller: _notes,
                  minLines: 2,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  style: context.type.body(c.ink),
                  decoration: const InputDecoration(hintText: 'Anything to know, like where the bags are'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _whoSection(AppState app) {
    final den = app.den;
    final c = context.colors;
    final people = den.members.where((m) => m.role != Role.guest).toList();
    final f = app.formats;
    String? preview;
    if (_kind == _OwnerKind.turns && _turns.length >= 2) {
      final r = _owner(app) as OwnerRotation;
      preview = rotationWords(
        r,
        app.today,
        app.today,
        f,
        (id) => den.member(id)?.name ?? 'someone',
        weekStart: den.family?.weekStart ?? 0,
      );
    }
    return [
      const FieldLabel('Who does it'),
      Align(
        alignment: Alignment.centerLeft,
        child: Segmented<_OwnerKind>(
          options: const {_OwnerKind.person: 'One person', _OwnerKind.anyone: 'Anyone', _OwnerKind.turns: 'Take turns'},
          value: _kind,
          onChanged: (k) => setState(() {
            _kind = k;
            _ownerError = null;
          }),
        ),
      ),
      if (_kind != _OwnerKind.anyone) ...[
        const SizedBox(height: Sp.m),
        Wrap(
          spacing: Sp.s,
          runSpacing: Sp.s,
          children: [
            for (final m in people)
              _kind == _OwnerKind.person
                  ? PersonChip(
                      member: m,
                      selected: _person == m.id,
                      onTap: () => setState(() {
                        _person = m.id;
                        _ownerError = null;
                      }),
                    )
                  : _TurnChip(
                      member: m,
                      position: _turns.indexOf(m.id),
                      onTap: () => setState(() {
                        if (!_turns.remove(m.id)) _turns.add(m.id);
                        _ownerError = null;
                      }),
                    ),
          ],
        ),
      ],
      if (_kind == _OwnerKind.turns) ...[
        const SizedBox(height: Sp.m),
        Row(
          children: [
            Segmented<String>(
              options: const {'day': 'Switch daily', 'week': 'Switch weekly'},
              value: _every,
              onChanged: (v) => setState(() => _every = v),
            ),
          ],
        ),
        if (preview != null)
          Padding(
            padding: const EdgeInsets.only(top: Sp.s),
            child: Text(preview, style: context.type.meta(c.ink2)),
          ),
      ],
      FieldError(_ownerError),
    ];
  }

  List<Widget> _whenSection(AppState app) {
    final spec = _spec!;
    final f = app.formats;
    final c = context.colors;
    final weekStart = app.den.family?.weekStart ?? 0;
    void set(Repeat r) => setState(() {
      spec.repeat = r;
      spec.raw = null;
      if (r == Repeat.everyWeeks && spec.interval < 2) spec.interval = 2;
      if (r == Repeat.daily) spec.interval = 1;
      _whenError = null;
    });
    const choices = {
      Repeat.daily: 'Every day',
      Repeat.weekdays: 'Weekdays',
      Repeat.days: 'Chosen days',
      Repeat.everyWeeks: 'Every few weeks',
      Repeat.monthly: 'Monthly',
      Repeat.once: 'Once',
    };
    return [
      FieldLabel('When', trailing: spec.raw != null ? Text(spec.words(f), style: context.type.meta(c.ink2)) : null),
      Wrap(
        spacing: Sp.s,
        children: [
          for (final e in choices.entries)
            InkChip(label: e.value, selected: spec.raw == null && spec.repeat == e.key, onTap: () => set(e.key)),
        ],
      ),
      const SizedBox(height: Sp.s),
      if (spec.repeat == Repeat.days && spec.raw == null)
        DayToggles(days: spec.days, weekStart: weekStart, onChanged: (d) => setState(() => spec.days = d)),
      if (spec.repeat == Repeat.everyWeeks && spec.raw == null) ...[
        Row(
          children: [
            Text('Every', style: context.type.body(c.ink)),
            const SizedBox(width: Sp.s),
            NumberStepper(
              label: 'Weeks between',
              value: spec.interval,
              min: 2,
              max: 12,
              onChanged: (v) => setState(() => spec.interval = v),
            ),
            const SizedBox(width: Sp.s),
            Text('weeks, on', style: context.type.body(c.ink)),
          ],
        ),
        const SizedBox(height: Sp.s),
        DayToggles(days: spec.days, weekStart: weekStart, onChanged: (d) => setState(() => spec.days = d)),
      ],
      if (spec.repeat == Repeat.monthly && spec.raw == null)
        Row(
          children: [
            Text('On day', style: context.type.body(c.ink)),
            const SizedBox(width: Sp.s),
            NumberStepper(
              label: 'Day of the month',
              value: spec.monthDay,
              min: 1,
              max: 31,
              onChanged: (v) => setState(() => spec.monthDay = v),
            ),
            if (spec.monthDay > 28) const InfoTip('Months without this day skip the chore.'),
          ],
        ),
      if (spec.repeat == Repeat.once)
        Align(
          alignment: Alignment.centerLeft,
          child: ValueButton(
            icon: PhosphorIconsRegular.calendarBlank,
            label: f.relative(spec.once, app.today),
            onPressed: () => _pickDate(spec.once, (d) => setState(() => spec.once = d)),
          ),
        ),
      if (spec.repeat != Repeat.once)
        Padding(
          padding: const EdgeInsets.only(top: Sp.xs),
          child: Row(
            children: [
              Text('Starting', style: context.type.body(c.ink2)),
              const SizedBox(width: Sp.s),
              TextButton(
                onPressed: () => _pickDate(spec.start, (d) => setState(() => spec.start = d)),
                child: Text(f.relative(spec.start, app.today)),
              ),
            ],
          ),
        ),
      FieldError(_whenError),
    ];
  }

  List<Widget> _stepsSection(AppState app, bool pointsOn) {
    final c = context.colors;
    return [
      const FieldLabel(
        'Steps',
        info:
            'A chore with steps is done when every step is checked. Each step can belong to someone and carry its own points.',
      ),
      if (_steps.isNotEmpty)
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          proxyDecorator: (child, _, _) => Material(
            color: c.paper,
            elevation: 8,
            shadowColor: c.ink.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(Radii.control),
            child: child,
          ),
          onReorder: (from, to) => setState(() {
            if (to > from) to--;
            _steps.insert(to, _steps.removeAt(from));
          }),
          children: [
            for (final (i, s) in _steps.indexed)
              _StepEditor(
                key: ValueKey(s.id),
                index: i,
                step: s,
                pointsOn: pointsOn,
                onChanged: () => setState(() {}),
                onRemove: () => setState(() {
                  _steps.remove(s);
                }),
              ),
          ],
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: Hang(
          by: Sp.m,
          child: TextButton.icon(
            onPressed: () => setState(() => _steps.add(_StepDraft(id: newId()))),
            icon: const Icon(PhosphorIconsBold.plus, size: 18),
            label: const Text('Add step'),
          ),
        ),
      ),
    ];
  }

  List<Widget> _audienceSection(AppState app) {
    final c = context.colors;
    final me = app.me;
    final options = {
      Audience.everyone: 'Everyone',
      if (me?.isParent ?? false) Audience.parents: 'Parents',
      Audience.justMe: 'Just me',
    };
    final owner = _existing == null ? null : Space.memberOf(_existing!.space);
    if (owner != null && owner != me?.id && !_audienceChanged) {
      // Someone else's private chore: say whose, and offer to share it more widely.
      final name = app.den.member(owner)?.name ?? 'one person';
      return [
        const FieldLabel('Who sees it'),
        Row(
          children: [
            Expanded(child: Text('Only $name', style: context.type.body(c.ink))),
            TextButton(
              onPressed: () => setState(() {
                _audience = Audience.everyone;
                _audienceChanged = true;
              }),
              child: const Text('Share with everyone'),
            ),
          ],
        ),
      ];
    }
    return [
      const FieldLabel('Who sees it'),
      Align(
        alignment: Alignment.centerLeft,
        child: Segmented<Audience>(
          options: options,
          value: options.containsKey(_audience) ? _audience : Audience.everyone,
          onChanged: (a) => setState(() {
            _audience = a;
            _audienceChanged = true;
          }),
        ),
      ),
    ];
  }
}

/// A person in a rotation: their place in the order replaces the avatar when chosen.
class _TurnChip extends StatelessWidget {
  const _TurnChip({required this.member, required this.position, required this.onTap});
  final Member member;
  final int position;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final selected = position >= 0;
    return Semantics(
      selected: selected,
      button: true,
      label: selected ? '${member.name}, turn ${position + 1}' : member.name,
      excludeSemantics: true,
      child: Material(
        color: selected ? c.ink : c.well,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DenAvatar(member, size: 30),
                  const SizedBox(width: Sp.s),
                  Text(member.name, style: context.type.body(selected ? c.onInk : c.ink)),
                  if (selected) ...[
                    const SizedBox(width: Sp.s),
                    Text('${position + 1}', style: context.type.bodyStrong(c.onInk)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepEditor extends StatelessWidget {
  const _StepEditor({
    super.key,
    required this.index,
    required this.step,
    required this.pointsOn,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final _StepDraft step;
  final bool pointsOn;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final owner = app.memberById(step.owner);
    final people = app.den.members.where((m) => m.role != Role.guest).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Tooltip(
              message: 'Drag to reorder',
              child: SizedBox(
                width: 32,
                height: Targets.adult,
                child: Icon(PhosphorIconsRegular.dotsSixVertical, color: c.ink2, size: 20),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: step.text,
                  textCapitalization: TextCapitalization.sentences,
                  style: context.type.body(c.ink),
                  decoration: InputDecoration(hintText: 'Step ${index + 1}'),
                ),
                Wrap(
                  spacing: Sp.s,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    PopupMenuButton<String>(
                      tooltip: 'Who does this step',
                      onSelected: (id) {
                        step.owner = id.isEmpty ? null : id;
                        onChanged();
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: '', child: Text('Whoever does the chore')),
                        for (final m in people)
                          PopupMenuItem(
                            value: m.id,
                            child: Row(
                              children: [
                                DenAvatar(m, size: 22),
                                const SizedBox(width: Sp.s),
                                Text(m.name),
                              ],
                            ),
                          ),
                      ],
                      child: _MenuFace(
                        leading: owner == null ? const AnyoneMark(size: 22) : DenAvatar(owner, size: 22),
                        label: owner?.name ?? 'Whoever does the chore',
                      ),
                    ),
                    if (pointsOn)
                      PopupMenuButton<int>(
                        tooltip: 'Points for this step',
                        onSelected: (p) {
                          step.points = p;
                          onChanged();
                        },
                        itemBuilder: (_) => [
                          for (final p in const [0, 1, 2, 3, 5, 10])
                            PopupMenuItem(
                              value: p,
                              child: p == 0 ? const Text('No points') : StarCount(p, style: context.type.body(c.ink)),
                            ),
                        ],
                        child: _MenuFace(
                          label: step.points == 0 ? 'No points' : null,
                          leading: step.points == 0 ? null : StarCount(step.points, style: context.type.body(c.ink)),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove step',
            onPressed: onRemove,
            icon: Icon(PhosphorIconsRegular.x, size: 18, color: c.ink2),
          ),
        ],
      ),
    );
  }
}

/// What a small menu button shows: an optional leading mark, a label and a caret.
class _MenuFace extends StatelessWidget {
  const _MenuFace({this.leading, this.label});
  final Widget? leading;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Targets.adult),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?leading,
            if (leading != null && label != null) const SizedBox(width: Sp.s),
            if (label != null) Text(label!, style: context.type.meta(c.ink)),
            const SizedBox(width: Sp.xs),
            Icon(PhosphorIconsRegular.caretDown, size: 14, color: c.ink2),
          ],
        ),
      ),
    );
  }
}
