import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../family/words/family_words.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../../../design/forms/forms.dart';

const Map<Scope, String> _scopeHelp = {
  Scope.read: 'See everything the person it acts as can see.',
  Scope.calendar: 'Add, change and delete events.',
  Scope.chores: 'Complete chores and check off steps.',
  Scope.lists: 'Add, check and remove list items.',
  Scope.points: 'Give and take points, and decide reward requests.',
  Scope.admin: 'Change people, devices and family settings.',
};

/// What a connection may do, as check boxes. [allowed] limits the choice when narrowing a
/// request to what it asked for.
class ScopePicker extends StatelessWidget {
  const ScopePicker({super.key, required this.value, required this.onChanged, this.allowed});

  final Set<Scope> value;
  final ValueChanged<Set<Scope>> onChanged;
  final Set<Scope>? allowed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final shown = [
      for (final s in Scope.values)
        if (allowed == null || allowed!.contains(s)) s,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Access'),
        for (final s in shown)
          CheckboxListTile(
            controlAffinity: ListTileControlAffinity.leading,
            title: Row(
              children: [
                Text(FamilyWords.scope(s), style: context.type.body(c.ink)),
                InfoTip(_scopeHelp[s]!),
              ],
            ),
            value: value.contains(s),
            onChanged: (on) => onChanged(on == true ? {...value, s} : ({...value}..remove(s))),
          ),
      ],
    );
  }
}

/// Whose permissions a connection uses: one person, or parent-level for household automations.
class ActsAsPicker extends StatelessWidget {
  const ActsAsPicker({super.key, required this.value, required this.onChanged});

  /// A member id, or null for parent-level.
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final selected = value == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const InfoHeader(
          'Acts as',
          info:
              'A connection can only do what this person could do themselves. Parent-level suits household automations.',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l),
          child: Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              Semantics(
                selected: selected,
                button: true,
                child: Material(
                  color: selected ? c.ink : c.well,
                  shape: const StadiumBorder(),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () => onChanged(null),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 40),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 4, 14, 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(PhosphorIconsRegular.shieldCheck, size: 20, color: selected ? c.onInk : c.ink2),
                            const SizedBox(width: Sp.s),
                            Text('Parent-level', style: context.type.body(selected ? c.onInk : c.ink)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              for (final m in context.den.members)
                PersonChip(member: m, selected: value == m.id, onTap: () => onChanged(m.id)),
            ],
          ),
        ),
      ],
    );
  }
}
