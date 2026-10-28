import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../design/pictograms.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../../../design/chore_pictograms.dart';
import '../../../design/forms/forms.dart';
import '../state/reward_actions.dart';
import '../state/points_model.dart';

/// A reward in the store: picture, name, cost, and whether a parent approves each request.
/// Removing one takes it out of the store, with Undo. `/points/reward/new`, `/points/reward/:id`.
class RewardEditorScreen extends StatefulWidget {
  const RewardEditorScreen({super.key, this.id});
  final String? id;

  @override
  State<RewardEditorScreen> createState() => _RewardEditorScreenState();
}

class _RewardEditorScreenState extends State<RewardEditorScreen> {
  final _title = TextEditingController();
  String _icon = 'gift';
  int _cost = 20;
  bool _needsApproval = true;
  bool _loaded = false;
  bool _saving = false;
  String? _titleError;
  Reward? _existing;

  bool get _isNew => widget.id == null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    if (widget.id == null) return;
    final reward = context.watch(pointsReads).den.points().rewards.where((r) => r.id == widget.id).firstOrNull;
    _existing = reward;
    if (reward == null) return;
    _title.text = reward.title;
    _icon = reward.icon;
    _cost = reward.cost;
    _needsApproval = reward.needsApproval;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final rewards = context.rewardActions;
    setState(() => _titleError = _title.text.trim().isEmpty ? 'Give the reward a name.' : null);
    if (_titleError != null) return;
    setState(() => _saving = true);
    final ok = await attempt(
      context,
      () => rewards.saveReward(_existing, title: _title.text.trim(), cost: _cost, icon: _icon, needsApproval: _needsApproval),
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

  Future<void> _remove() async {
    final reward = _existing!;
    final actions = context.actions;
    final keep = Navigator.of(context, rootNavigator: true).context;
    final result = await perform(context, () => RewardActions(actions).setRewardActive(reward, false));
    if (result == null || !mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/points');
    }
    if (!keep.mounted) return;
    offerUndo(keep, actions, '${reward.title} removed', result);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(pointsReads);
    final c = context.colors;
    if (!app.allows(DenAction.managePoints)) {
      return Scaffold(
        appBar: AppBar(title: Text(_isNew ? 'New reward' : 'Edit reward')),
        body: const EmptyLine(message: 'Rewards are set by parents.'),
      );
    }
    if (!_isNew && _existing == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit reward')),
        body: EmptyLine(
          message: 'This reward was removed.',
          actionLabel: 'Go to points',
          onAction: () => context.go('/points'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New reward' : 'Edit reward'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: Sp.s),
            child: FilledButton(onPressed: _saving ? null : _save, child: Text(_isNew ? 'Add reward' : 'Save reward')),
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
                const FieldLabel('Reward', top: Sp.s),
                TextField(
                  controller: _title,
                  autofocus: _isNew,
                  textCapitalization: TextCapitalization.sentences,
                  style: context.type.body(c.ink),
                  decoration: const InputDecoration(hintText: 'Ice cream after dinner'),
                  onChanged: (_) {
                    if (_titleError != null) setState(() => _titleError = null);
                  },
                ),
                FieldError(_titleError),
                const FieldLabel('Picture'),
                PictogramGrid(
                  icons: HomePictograms.withCurrent(Pictograms.rewards, _icon, HomePictograms.reward(_icon)),
                  value: _icon,
                  onChanged: (k) => setState(() => _icon = k),
                ),
                const FieldLabel('Cost'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: NumberStepper(
                    label: 'Cost',
                    value: _cost,
                    min: 1,
                    max: 10000,
                    onChanged: (v) => setState(() => _cost = v),
                    suffix: const Star(size: 18),
                  ),
                ),
                Wrap(
                  spacing: Sp.s,
                  children: [
                    for (final n in const [5, 10, 20, 50])
                      ChoiceTile.chip(label: '$n', selected: _cost == n, onTap: () => setState(() => _cost = n)),
                  ],
                ),
                const SizedBox(height: Sp.l),
                SwitchRow(
                  label: 'A parent approves each request',
                  info: 'When off, asking for it spends the points right away.',
                  value: _needsApproval,
                  onChanged: (v) => setState(() => _needsApproval = v),
                ),
                if (!_isNew) ...[
                  const SizedBox(height: Sp.xxl),
                  DestructiveButton(label: 'Remove reward', onPressed: _remove),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
