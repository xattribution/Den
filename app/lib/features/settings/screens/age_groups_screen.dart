import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/forms/choices.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../family/family.dart' show TrustActionsOf;

/// Settings → Family → Age groups: where each age group starts, and which group the AI helper
/// and keeping things private start from. Every label and rule that goes by age follows these;
/// each kid's group stays a parent's choice on their page.
class AgeGroupsScreen extends StatefulWidget {
  const AgeGroupsScreen({super.key});

  @override
  State<AgeGroupsScreen> createState() => _AgeGroupsScreenState();
}

class _AgeGroupsScreenState extends State<AgeGroupsScreen> {
  String? _error;

  Future<void> _save(AgeGroups next) async {
    final trust = context.trustActions;
    final problem = await tryWrite(() => trust.setAgeGroups(next));
    if (mounted) setState(() => _error = problem);
  }

  AgeGroups _with(AgeGroups g, {int? little, int? big, int? teen, Tier? assistant, Tier? private}) => AgeGroups(
        little: little ?? g.little,
        big: big ?? g.big,
        teen: teen ?? g.teen,
        assistantFrom: assistant ?? g.assistantFrom,
        privateFrom: private ?? g.privateFrom,
      );

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.family});
    final c = context.colors;
    final t = context.text;
    final g = app.den.family?.groups ?? const AgeGroups();
    final parent = app.allowsTrust(DenAction.manageFamily);

    Widget start(String label, int value, int min, int max, ValueChanged<int> set) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.xs),
          child: Row(
            children: [
              Expanded(child: Text(label, style: t.body(c.ink))),
              IconButton(
                onPressed: parent && value > min ? () => set(value - 1) : null,
                icon: const Icon(PhosphorIconsBold.minus, size: 20),
                tooltip: 'Younger',
              ),
              SizedBox(
                width: 40,
                child: Text('$value', textAlign: TextAlign.center, style: t.rowTitle(c.ink)),
              ),
              IconButton(
                onPressed: parent && value < max ? () => set(value + 1) : null,
                icon: const Icon(PhosphorIconsBold.plus, size: 20),
                tooltip: 'Older',
              ),
            ],
          ),
        );

    Widget from(Tier value, ValueChanged<Tier> set) => Wrap(
          spacing: Sp.s,
          runSpacing: Sp.s,
          children: [
            for (final tier in Tier.values)
              ChoiceTile.chip(
                label: tier == Tier.preReader ? 'Everyone' : g.label(tier),
                selected: tier == value,
                onTap: parent ? () => set(tier) : () {},
              ),
          ],
        );

    return DenPage(
      title: 'Age groups',
      children: [
        if (!parent)
          const NoticeLine(icon: PhosphorIconsRegular.lockKey, message: "Age groups are set on a parent's own phone."),
        DenSection(
          title: 'Each group starts at',
          child: Column(
            children: ruled([
              start('Little kids', g.little, AgeGroups.youngest, g.big - 1, (v) => _save(_with(g, little: v))),
              start('Big kids', g.big, g.little + 1, g.teen - 1, (v) => _save(_with(g, big: v))),
              start('Teens', g.teen, g.big + 1, AgeGroups.oldest, (v) => _save(_with(g, teen: v))),
            ], indent: 0),
          ),
        ),
        Text(
          [for (final tier in Tier.values) g.label(tier)].join(' · '),
          style: t.meta(c.ink2),
        ),
        DenSection(
          title: 'AI helper, from',
          carded: false,
          child: from(g.assistantFrom, (v) => _save(_with(g, assistant: v))),
        ),
        DenSection(
          title: 'Can keep things private, from',
          carded: false,
          child: from(g.privateFrom, (v) => _save(_with(g, private: v))),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
            child: Semantics(liveRegion: true, child: Text(_error!, style: t.meta(c.destructive))),
          ),
      ],
    );
  }
}
