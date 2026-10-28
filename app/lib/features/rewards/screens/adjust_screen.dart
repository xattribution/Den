import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../../../design/forms/forms.dart';
import '../state/reward_actions.dart';

/// A parent gives or takes points: who, how many, and why (a reason is required so everyone
/// can see it in Recent). `/points/adjust?member=`.
class AdjustScreen extends StatefulWidget {
  const AdjustScreen({super.key, this.member, this.returnsToPoints = false});

  final String? member;

  /// Opened from the points screen: go back there instead of replacing this page with it.
  final bool returnsToPoints;

  @override
  State<AdjustScreen> createState() => _AdjustScreenState();
}

class _AdjustScreenState extends State<AdjustScreen> {
  late String? _member = widget.member;
  bool _take = false;
  int _amount = 1;
  final _reason = TextEditingController();
  String? _memberError;
  String? _reasonError;
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _memberError = _member == null ? 'Choose who gets the points.' : null;
      _reasonError = _reason.text.trim().isEmpty ? 'Add a reason, so everyone can see why.' : null;
    });
    if (_memberError != null || _reasonError != null) return;
    setState(() => _saving = true);
    final ok = await attempt(
      context,
      () => context.rewardActions.adjust(_member!, _take ? -_amount : _amount, _reason.text.trim()),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) return;
    if (widget.returnsToPoints && context.canPop()) {
      context.pop();
    } else {
      context.pushReplacement('/points');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final den = app.den;
    if (!(den.family?.pointsEnabled ?? true)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Give or take points')),
        body: const EmptyLine(message: 'Points are turned off for this family. A parent can turn them on in Settings.'),
      );
    }
    if (!app.allows(DenAction.managePoints)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Give or take points')),
        body: const EmptyLine(message: 'Giving and taking points is for parents.'),
      );
    }
    // Nobody gives or takes their own points.
    final people = [
      ...den.members.where((m) => m.isKid && m.id != app.me?.id),
      ...den.members.where((m) => !m.isKid && m.role != Role.guest && m.id != app.me?.id),
    ];
    final who = app.memberById(_member)?.name;
    final noun = _amount == 1 ? 'point' : 'points';
    final label = who == null
        ? (_take ? 'Take points' : 'Give points')
        : (_take ? 'Take $_amount $noun from $who' : 'Give $_amount $noun to $who');

    return Scaffold(
      appBar: AppBar(title: const Text('Give or take points')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.xxxl),
        children: [
          FormWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const FieldLabel('Who', top: Sp.s),
                Wrap(
                  spacing: Sp.s,
                  runSpacing: Sp.s,
                  children: [
                    for (final m in people)
                      PersonChip(
                        member: m,
                        selected: _member == m.id,
                        onTap: () => setState(() {
                          _member = m.id;
                          _memberError = null;
                        }),
                      ),
                  ],
                ),
                FieldError(_memberError),
                const FieldLabel('Give or take'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Segmented<bool>(
                    options: const {false: 'Give', true: 'Take'},
                    value: _take,
                    onChanged: (v) => setState(() => _take = v),
                  ),
                ),
                const FieldLabel('How many'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: NumberStepper(
                    label: 'Points',
                    value: _amount,
                    min: 1,
                    max: 1000,
                    onChanged: (v) => setState(() => _amount = v),
                    suffix: const Star(size: 18),
                  ),
                ),
                Wrap(
                  spacing: Sp.s,
                  children: [
                    for (final n in const [1, 2, 5, 10, 20])
                      ChoiceTile.chip(label: '$n', selected: _amount == n, onTap: () => setState(() => _amount = n)),
                  ],
                ),
                const FieldLabel('Reason'),
                TextField(
                  controller: _reason,
                  textCapitalization: TextCapitalization.sentences,
                  style: context.type.body(c.ink),
                  decoration: InputDecoration(
                    hintText: _take ? 'Left the bikes out in the rain' : 'Helped carry the groceries',
                  ),
                  onChanged: (_) {
                    if (_reasonError != null) setState(() => _reasonError = null);
                  },
                  onSubmitted: (_) => _save(),
                ),
                FieldError(_reasonError),
                const SizedBox(height: Sp.xl),
                FilledButton(onPressed: _saving ? null : _save, child: Text(label)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
