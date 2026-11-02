import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../family/family.dart';
import 'hub_adoption_panel.dart';

/// The short step after starting a family: the people in it, each grown-up with Invite, and Add
/// someone (a name, who they are, Add). A grown-up added here gets their invite straight away.
/// Everything here can also be done later in Family.
class AddPeopleScreen extends StatelessWidget {
  const AddPeopleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final t = context.text;
    final members = app.den.members;
    final me = app.me;
    final others = members.where((m) => m.id != me?.id).toList();

    return DenPage(
      title: 'Add people',
      back: false,
      bottom: others.isEmpty
          ? OutlinedButton(
              onPressed: () => context.go('/today'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: const Text('Skip for now'),
            )
          : FilledButton(
              onPressed: () => context.go('/today'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: const Text('Go to Today'),
            ),
      children: [
        const Ungapped(HubAdoptionPanel()),
        GroupCard(
          child: Column(
            children: ruled([
              for (final m in members)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 64),
                  child: Row(
                    children: [
                      DenAvatar(m, size: 40),
                      const SizedBox(width: Sp.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.id == me?.id ? '${m.name} (you)' : m.name, style: t.rowTitle(c.ink)),
                            Text(FamilyWords.memberLine(m, app.today), style: t.meta(c.ink2)),
                          ],
                        ),
                      ),
                      if (m.id != me?.id && !m.isKid)
                        TextButton(onPressed: () => showInviteSheet(context, memberId: m.id), child: const Text('Invite')),
                    ],
                  ),
                ),
              NavRow(
                icon: PhosphorIconsRegular.userPlus,
                label: 'Add someone',
                detail: 'Kids, your partner, a grandparent, a sitter',
                chevron: false,
                onTap: () => _add(context),
              ),
            ], indent: 52),
          ),
        ),
      ],
    );
  }

  Future<void> _add(BuildContext context) async {
    final id = await showDenSheet<String>(context, builder: (_) => const QuickAddSheet());
    if (id == null || !context.mounted) return;
    final m = DenScope.read(context).den.member(id);
    // A grown-up gets their invite right away: the partner's phone is usually next.
    if (m != null && !m.isKid) await showInviteSheet(context, memberId: m.id);
  }
}
