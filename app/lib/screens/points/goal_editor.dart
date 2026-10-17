import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/parts/home_form.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';

/// A points goal: who's in it, the target, whether everyone can reach it or the first one wins,
/// the window it counts over, and what it's for. `/points/goal/new`, `/points/goal/:id`.
class GoalEditorScreen extends StatefulWidget {
  const GoalEditorScreen({super.key, this.id});
  final String? id;

  @override
  State<GoalEditorScreen> createState() => _GoalEditorScreenState();
}

class _GoalEditorScreenState extends State<GoalEditorScreen> {
  final _title = TextEditingController();
  final _reward = TextEditingController();
  GoalMode _mode = GoalMode.target;
  int _target = 50;

  /// Null means every kid.
  List<String>? _members;
  GoalRepeat _repeat = GoalRepeat.monthly;
  String? _start;
  String? _end;
  bool _loaded = false;
  bool _saving = false;
  String? _titleError;
  String? _membersError;
  Goal? _existing;

  bool get _isNew => widget.id == null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final app = context.app;
    _start = app.today;
    if (widget.id == null) return;
    final goal = app.den.points().goals.map((g) => g.goal).where((g) => g.id == widget.id).firstOrNull;
    _existing = goal;
    if (goal == null) return;
    _title.text = goal.title;
    _reward.text = goal.reward;
    _mode = goal.mode;
    _target = goal.target;
    _members = goal.members == null ? null : [...goal.members!];
    _repeat = goal.repeat;
    _start = goal.start.isEmpty ? app.today : goal.start;
    _end = goal.end;
  }

  @override
  void dispose() {
    _title.dispose();
    _reward.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final den = context.den;
    setState(() {
      _titleError = _title.text.trim().isEmpty ? 'Give the goal a name.' : null;
      _membersError = _members != null && _members!.isEmpty ? 'Choose who is in it, or choose every kid.' : null;
    });
    if (_titleError != null || _membersError != null) return;
    setState(() => _saving = true);
    final end = _repeat == GoalRepeat.none ? _end : null;
    final ok = await attempt(context, () async {
      if (_isNew) {
        await den.addGoal(
          title: _title.text.trim(),
          target: _target,
          mode: _mode,
          members: _members,
          start: _start,
          end: end,
          repeat: _repeat,
          reward: _reward.text.trim(),
        );
      } else {
        await den.updateGoal(widget.id!, {
          'title': _title.text.trim(),
          'target': _target,
          'mode': _mode.name,
          'members': _members,
          'start': _start,
          'end': end,
          'repeat': _repeat.name,
          'reward': _reward.text.trim(),
        });
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/points');
    }
  }

  Future<void> _delete() async {
    final goal = _existing!;
    final den = context.den;
    final keep = Navigator.of(context, rootNavigator: true).context;
    final ok = await attempt(context, () => den.deleteGoal(goal.id));
    if (!ok || !mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/points');
    }
    if (!keep.mounted) return;
    showUndo(
      keep,
      '${goal.title} deleted',
      () => attempt(
        keep,
        () => den.addGoal(
          title: goal.title,
          target: goal.target,
          mode: goal.mode,
          members: goal.members,
          start: goal.start,
          end: goal.end,
          repeat: goal.repeat,
          reward: goal.reward,
        ),
      ),
    );
  }

  Future<void> _pickDate(String? initial, ValueChanged<String> onPicked) async {
    final app = context.app;
    final d = app.formats.dateTime(initial ?? app.today);
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
    final f = app.formats;
    if (!app.allows(DenAction.managePoints)) {
      return Scaffold(
        appBar: AppBar(title: Text(_isNew ? 'New goal' : 'Edit goal')),
        body: const EmptyLine(message: 'Goals are set by parents.'),
      );
    }
    if (!_isNew && _existing == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit goal')),
        body: EmptyLine(
          message: 'This goal was deleted.',
          actionLabel: 'Go to points',
          onAction: () => context.go('/points'),
        ),
      );
    }
    final people = app.den.members.where((m) => m.role != Role.guest).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New goal' : 'Edit goal'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: Sp.s),
            child: FilledButton(onPressed: _saving ? null : _save, child: Text(_isNew ? 'Add goal' : 'Save goal')),
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
                const FieldLabel('Goal', top: Sp.s),
                TextField(
                  controller: _title,
                  autofocus: _isNew,
                  textCapitalization: TextCapitalization.sentences,
                  style: context.type.body(c.ink),
                  decoration: const InputDecoration(hintText: 'Movie night'),
                  onChanged: (_) {
                    if (_titleError != null) setState(() => _titleError = null);
                  },
                ),
                FieldError(_titleError),
                const FieldLabel('Who is in it'),
                Wrap(
                  spacing: Sp.s,
                  runSpacing: Sp.s,
                  children: [
                    AnyoneChip(
                      label: 'Every kid',
                      selected: _members == null,
                      onTap: () => setState(() {
                        _members = _members == null ? [] : null;
                        _membersError = null;
                      }),
                    ),
                    for (final m in people)
                      PersonChip(
                        member: m,
                        selected: _members?.contains(m.id) ?? false,
                        onTap: () => setState(() {
                          final next = [...?_members];
                          if (!next.remove(m.id)) next.add(m.id);
                          _members = next;
                          _membersError = null;
                        }),
                      ),
                  ],
                ),
                FieldError(_membersError),
                const FieldLabel('How it is won'),
                Wrap(
                  spacing: Sp.s,
                  children: [
                    InkChip(
                      label: 'Everyone who reaches it',
                      selected: _mode == GoalMode.target,
                      onTap: () => setState(() => _mode = GoalMode.target),
                    ),
                    InkChip(
                      label: 'First to reach it',
                      selected: _mode == GoalMode.race,
                      onTap: () => setState(() => _mode = GoalMode.race),
                    ),
                  ],
                ),
                const FieldLabel('Target', info: 'Only points earned while the goal counts add up toward it.'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: NumberStepper(
                    label: 'Target',
                    value: _target,
                    min: 1,
                    max: 10000,
                    onChanged: (v) => setState(() => _target = v),
                    suffix: const Star(size: 18),
                  ),
                ),
                Wrap(
                  spacing: Sp.s,
                  children: [
                    for (final n in const [10, 25, 50, 100])
                      InkChip(label: '$n', selected: _target == n, onTap: () => setState(() => _target = n)),
                  ],
                ),
                const FieldLabel('Counts'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Segmented<GoalRepeat>(
                    options: const {
                      GoalRepeat.weekly: 'Each week',
                      GoalRepeat.monthly: 'Each month',
                      GoalRepeat.none: 'Once',
                    },
                    value: _repeat,
                    onChanged: (v) => setState(() => _repeat = v),
                  ),
                ),
                if (_repeat == GoalRepeat.none) ...[
                  const SizedBox(height: Sp.m),
                  Wrap(
                    spacing: Sp.s,
                    runSpacing: Sp.s,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('From', style: context.type.body(c.ink2)),
                      ValueButton(
                        icon: PhosphorIconsRegular.calendarBlank,
                        label: f.relative(_start!, app.today),
                        onPressed: () => _pickDate(_start, (d) => setState(() => _start = d)),
                      ),
                      Text('until', style: context.type.body(c.ink2)),
                      ValueButton(
                        icon: PhosphorIconsRegular.calendarBlank,
                        label: _end == null ? 'No end' : f.relative(f.addDays(_end!, -1), app.today),
                        onPressed: () => _pickDate(
                          _end == null ? null : f.addDays(_end!, -1),
                          (d) => setState(() => _end = f.addDays(d, 1)),
                        ),
                        onClear: _end == null ? null : () => setState(() => _end = null),
                      ),
                    ],
                  ),
                ],
                const FieldLabel('Reward for reaching it'),
                TextField(
                  controller: _reward,
                  textCapitalization: TextCapitalization.sentences,
                  style: context.type.body(c.ink),
                  decoration: const InputDecoration(hintText: 'Pick the movie'),
                ),
                if (!_isNew) ...[
                  const SizedBox(height: Sp.xxl),
                  DestructiveButton(label: 'Delete goal', onPressed: _delete),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
