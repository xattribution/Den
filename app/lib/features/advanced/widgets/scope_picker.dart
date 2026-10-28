import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../family/family.dart';

const Map<Scope, String> _scopeHelp = {
  Scope.read: 'See what the person it acts as can see',
  Scope.calendar: 'Add, change and delete events',
  Scope.chores: 'Check off chores and their steps',
  Scope.lists: 'Add, check off and remove list items',
  Scope.points: 'Give stars and decide reward requests',
  Scope.admin: 'Change people and family settings',
};

/// What a connection may do, as switches. [allowed] limits the choice when narrowing a request
/// to what it asked for.
class ScopePicker extends StatelessWidget {
  const ScopePicker({super.key, required this.value, required this.onChanged, this.allowed});

  final Set<Scope> value;
  final ValueChanged<Set<Scope>> onChanged;
  final Set<Scope>? allowed;

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final s in Scope.values)
        if (allowed == null || allowed!.contains(s)) s,
    ];
    return DenSection(
      title: 'What it may do',
      child: Column(
        children: ruled([
          for (final s in shown)
            SwitchLine(
              label: FamilyWords.scope(s),
              detail: _scopeHelp[s],
              value: value.contains(s),
              onChanged: (on) => onChanged(on ? {...value, s} : ({...value}..remove(s))),
            ),
        ]),
      ),
    );
  }
}

/// Whose permissions a connection uses: one person, or a parent's for household automations.
class ActsAsPicker extends StatelessWidget {
  const ActsAsPicker({super.key, required this.value, required this.onChanged});

  /// A member id, or null for a parent's.
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DenSection(
      title: 'Acts as',
      carded: false,
      child: Wrap(
        spacing: Sp.s,
        runSpacing: Sp.s,
        children: [
          PersonPill(
            face: Icon(PhosphorIconsRegular.shieldCheck, size: 24, color: c.ink),
            name: 'A parent',
            selected: value == null,
            onTap: () => onChanged(null),
          ),
          for (final m in context.watch(const {}).den.members)
            PersonPill(face: DenAvatar(m, size: 32), name: m.name, selected: value == m.id, onTap: () => onChanged(m.id)),
        ],
      ),
    );
  }
}
