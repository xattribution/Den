import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/forms/forms.dart' show NumberStepper;
import '../../../design/layout.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../state/points_model.dart';
import '../state/reward_actions.dart';

/// Give points: the sheet over the page. Completes with what it did, or null when closed.
Future<Done?> showGiveStars(BuildContext context, {String? member}) => showDenSheet<Done>(
      context,
      builder: (sheet) => Padding(
        padding: EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.xl + MediaQuery.viewInsetsOf(sheet).bottom),
        child: SingleChildScrollView(
          child: GiveStarsForm(member: member, onDone: (given) => Navigator.of(sheet).pop(given)),
        ),
      ),
    );

/// A parent gives or takes stars: who, how many and why. The reason is required, so everyone
/// sees in Recent why stars came or went. Nobody gives themselves stars.
class GiveStarsForm extends StatefulWidget {
  const GiveStarsForm({super.key, this.member, required this.onDone});

  final String? member;
  final ValueChanged<Done> onDone;

  @override
  State<GiveStarsForm> createState() => _GiveStarsFormState();
}

class _GiveStarsFormState extends State<GiveStarsForm> {
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
      _memberError = _member == null ? 'Choose who gets the stars.' : null;
      _reasonError = _reason.text.trim().isEmpty ? 'Add a reason, so everyone can see why.' : null;
    });
    if (_memberError != null || _reasonError != null) return;
    final app = DenScope.read(context);
    setState(() => _saving = true);
    final result = await perform(
      context,
      () => context.rewardActions.adjust(_member!, _take ? -_amount : _amount, _reason.text.trim()),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result == null) return;
    final name = app.memberById(_member)?.name ?? 'them';
    final stars = '$_amount ${_amount == 1 ? 'star' : 'stars'}';
    widget.onDone((message: _take ? 'Took $stars from $name' : 'Gave $name $stars', receipt: result.receipt));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(pointsReads);
    final c = context.colors;
    final t = context.text;
    final den = app.den;
    final people = [
      ...den.members.where((m) => m.isKid && m.id != app.me?.id),
      ...den.members.where((m) => !m.isKid && m.role != Role.guest && m.id != app.me?.id),
    ];
    final who = app.memberById(_member)?.name;
    final noun = _amount == 1 ? 'star' : 'stars';
    final label = who == null
        ? (_take ? 'Take stars' : 'Give stars')
        : (_take ? 'Take $_amount $noun from $who' : 'Give $who $_amount $noun');
    Widget label0(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.xl, 0, Sp.s),
          child: Text(text, style: t.meta(c.ink2)),
        );
    Widget error(String? message) => message == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.xs, 0, 0),
            child: Text(message, style: t.meta(c.destructive)),
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.xs, 0, 0),
          child: Row(
            children: [
              Expanded(child: Semantics(header: true, child: Text(_take ? 'Take stars' : 'Give stars', style: t.sheetTitle(c.ink)))),
              DenSegmented<bool>(
                options: const {false: 'Give', true: 'Take'},
                value: _take,
                onChanged: (v) => setState(() => _take = v),
              ),
            ],
          ),
        ),
        label0('Who'),
        Wrap(
          spacing: Sp.s,
          runSpacing: Sp.s,
          children: [
            for (final m in people)
              PersonPill(
                face: DenAvatar(m, size: 32),
                name: m.name,
                selected: _member == m.id,
                onTap: () => setState(() {
                  _member = m.id;
                  _memberError = null;
                }),
              ),
          ],
        ),
        error(_memberError),
        label0('How many'),
        Wrap(
          spacing: Sp.s,
          runSpacing: Sp.s,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            NumberStepper(
              label: 'Stars',
              value: _amount,
              min: 1,
              max: 1000,
              onChanged: (v) => setState(() => _amount = v),
              suffix: const Star(size: 18),
            ),
            for (final n in const [1, 2, 5, 10])
              TagChip(label: '$n', selected: _amount == n, onTap: () => setState(() => _amount = n)),
          ],
        ),
        label0('Why'),
        TextField(
          controller: _reason,
          textCapitalization: TextCapitalization.sentences,
          style: t.body(c.ink),
          decoration: InputDecoration(hintText: _take ? 'Left the bikes out in the rain' : 'Helped carry the groceries'),
          onChanged: (_) {
            if (_reasonError != null) setState(() => _reasonError = null);
          },
          onSubmitted: (_) => _save(),
        ),
        error(_reasonError),
        const SizedBox(height: Sp.xl),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: Text(label),
        ),
      ],
    );
  }
}
