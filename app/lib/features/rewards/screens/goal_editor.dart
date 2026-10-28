import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../../../design/forms/forms.dart';
import '../state/reward_actions.dart';
import '../state/points_model.dart';

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
  int _target = 25;

  /// Null means every kid.
  List<String>? _members;
  GoalRepeat _repeat = GoalRepeat.weekly;
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
    final app = context.watch(pointsReads);
    _start = app.today;
    if (widget.id == null) return;
    final goal = app.den.points().goals.map((g) => g.goal).where((g) => g.id == widget.id).firstOrNull;
    _existing = goal;
    if (goal == null) return;
    _title.text = goal.title;
    _reward.text = goal.reward;
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
    final rewards = context.rewardActions;
    setState(() {
      _titleError = _title.text.trim().isEmpty ? 'Give the goal a name.' : null;
      _membersError = _members != null && _members!.isEmpty ? 'Choose who is in it, or choose every kid.' : null;
    });
    if (_titleError != null || _membersError != null) return;
    setState(() => _saving = true);
    final end = _repeat == GoalRepeat.none ? _end : null;
    final ok = await attempt(
      context,
      () => rewards.saveGoal(
        _existing,
        title: _title.text.trim(),
        target: _target,
        // One kind of goal: everyone in it who reaches the target gets there. A race stored by
        // an older app becomes one when it's saved here.
        mode: GoalMode.target,
        members: _members,
        start: _start,
        end: end,
        repeat: _repeat,
        reward: _reward.text.trim(),
      ),
    );
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
    final actions = context.actions;
    final keep = Navigator.of(context, rootNavigator: true).context;
    final result = await perform(context, () => RewardActions(actions).deleteGoal(goal));
    if (result == null || !mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/points');
    }
    if (!keep.mounted) return;
    // The same goal comes back, not a copy.
    offerUndo(keep, actions, '${goal.title} deleted', result);
  }

  /// The goal in one line: "Reach 25 stars by Saturday, each week".
  String _sentence(AppState app) {
    final f = app.formats;
    final weekStart = app.den.family?.weekStart ?? 0;
    // The week's last day: the day before the week starts again.
    final last = DateFormat('EEEE').format(DateTime.utc(2026, 1, 4 + (weekStart + 6) % 7));
    return switch (_repeat) {
      GoalRepeat.weekly => 'Reach $_target stars by $last, each week',
      GoalRepeat.monthly => 'Reach $_target stars by the end of each month',
      GoalRepeat.none => _end == null
          ? 'Reach $_target stars, starting ${f.relative(_start!, app.today).toLowerCase()}'
          : 'Reach $_target stars by ${f.short(_end!)}',
    };
  }

  Future<void> _pickDate(String? initial, ValueChanged<String> onPicked) async {
    final app = context.watch(pointsReads);
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
    final app = context.watch(pointsReads);
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
                      PersonPill(
                        face: DenAvatar(m, size: 32),
                        name: m.name,
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
                const FieldLabel('Stars to reach', info: 'Only stars earned while the goal counts add up toward it.'),
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
                const SizedBox(height: Sp.s),
                Wrap(
                  spacing: Sp.s,
                  runSpacing: Sp.s,
                  children: [
                    for (final n in const [10, 25, 50, 100])
                      TagChip(label: '$n', selected: _target == n, onTap: () => setState(() => _target = n)),
                  ],
                ),
                const FieldLabel('Counts'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DenSegmented<GoalRepeat>(
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
                      PickerButton.outlined(
                        icon: PhosphorIconsRegular.calendarBlank,
                        label: f.relative(_start!, app.today),
                        onTap: () => _pickDate(_start, (d) => setState(() => _start = d)),
                      ),
                      Text('until', style: context.type.body(c.ink2)),
                      PickerButton.outlined(
                        icon: PhosphorIconsRegular.calendarBlank,
                        label: _end == null ? 'No end' : f.relative(_end!, app.today),
                        onTap: () => _pickDate(
                          _end,
                          (d) => setState(() => _end = d),
                        ),
                        onClear: _end == null ? null : () => setState(() => _end = null),
                      ),
                    ],
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.only(top: Sp.m),
                  child: Text(_sentence(app), style: context.text.meta(c.ink2)),
                ),
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
