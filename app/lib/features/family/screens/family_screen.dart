import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../app/family_label.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../widgets/family_needs_card.dart';
import '../widgets/family_parts.dart';
import '../widgets/invite_sheet.dart';
import '../widgets/person_page.dart';
import '../widgets/person_sheets.dart';
import '../widgets/quick_add_sheet.dart';

/// Family (Family.dc.html): what needs a parent first, then the family's faces with the chosen
/// person's page under them, then the few things a parent does from here (invite someone, the
/// AI helper, settings). On iPad the people are a list on the left and the person's page on the
/// right.
class FamilyScreen extends StatefulWidget {
  const FamilyScreen({super.key, this.selected});

  /// Whose page shows first; the person using the device by default.
  final String? selected;

  /// The content width from which people and their page sit side by side.
  static const double twoColumns = 760;

  @override
  State<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends State<FamilyScreen> {
  late String? _selected = widget.selected;

  @override
  void didUpdateWidget(FamilyScreen old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected && widget.selected != null) _selected = widget.selected;
  }

  Future<void> _add() async {
    final id = await showQuickAddSheet(context);
    if (id != null && mounted) setState(() => _selected = id);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.connection});
    final den = app.den;
    final people = den.members;
    final manage = app.allows(DenAction.manageFamily);
    final trust = app.allowsTrust(DenAction.manageFamily);
    final selected = den.member(_selected ?? '') ?? app.me ?? people.firstOrNull;
    final width = MediaQuery.sizeOf(context).width;
    final two = width - 2 * DenPage.gutterFor(width) >= FamilyScreen.twoColumns;

    final more = _More(manage: manage, trust: trust, onAdd: two ? null : _add);
    final person = selected == null
        ? const EmptyState(message: 'Nobody is in the family yet.')
        : PersonPage(key: ValueKey(selected.id), member: selected.id);
    void pick(String id) => setState(() => _selected = id);

    if (!two) {
      return DenPage(
        title: 'Family',
        children: [
          const FamilyLabel(),
          if (trust) const Ungapped(FamilyNeedsCard()),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PeopleStrip(
                people: people,
                selected: selected?.id,
                me: app.me?.id,
                onSelect: pick,
                onAdd: manage ? _add : null,
              ),
              const SizedBox(height: Sp.m),
              person,
            ],
          ),
          more,
        ],
      );
    }
    return DenPage(
      title: 'Family',
      maxWidth: 1100,
      children: [
        const FamilyLabel(),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 340,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (trust) const FamilyNeedsCard(),
                  PeopleList(
                    people: people,
                    selected: selected?.id,
                    me: app.me?.id,
                    today: app.today,
                    onSelect: pick,
                    onAdd: manage ? _add : null,
                  ),
                  const SizedBox(height: DenLayout.sectionGap),
                  more,
                ],
              ),
            ),
            const SizedBox(width: Sp.xl),
            Expanded(child: person),
          ],
        ),
      ],
    );
  }
}

/// What a parent does from Family besides people: invite someone, the AI helper, settings.
class _More extends StatelessWidget {
  const _More({required this.manage, required this.trust, this.onAdd});

  final bool manage;
  final bool trust;
  final VoidCallback? onAdd;

  /// Hands this phone to a kid: their screen until the parent's PIN takes it back. A parent
  /// with no PIN sets one first.
  Future<void> _handToKid(BuildContext context, List<Member> kids) async {
    final router = GoRouter.of(context);
    final pick = await showPeoplePicker(context, title: 'Who gets the phone?', people: kids);
    final kid = pick?.member;
    if (kid == null || !context.mounted) return;
    final me = DenScope.read(context).me;
    if (me != null && me.signIn.kind == 'none') {
      await showSignInSheet(context, me);
      if (!context.mounted || DenScope.read(context).me?.signIn.kind == 'none') return;
    }
    router.go('/kid/$kid');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final helper = app.den.family?.assistant.enabled ?? false;
    final kids = [for (final m in app.den.members) if (m.isKid) m];
    final rows = <Widget>[
      if (manage && onAdd != null) NavRow(icon: PhosphorIconsRegular.plusCircle, label: 'Add someone', onTap: onAdd),
      if (trust) NavRow(icon: PhosphorIconsRegular.userPlus, label: 'Invite someone', onTap: () => showInviteSheet(context)),
      if (trust && kids.isNotEmpty)
        NavRow(
          icon: PhosphorIconsRegular.smiley,
          label: 'Hand to a kid',
          value: 'Kid mode',
          onTap: () => _handToKid(context, kids),
        ),
      if (manage)
        NavRow(
          icon: PhosphorIconsRegular.chatCircle,
          label: 'AI helper',
          value: helper ? 'On' : 'Off',
          onTap: () => context.push('/settings/assistant'),
        ),
      NavRow(icon: PhosphorIconsRegular.gearSix, label: 'Settings', onTap: () => context.push('/settings')),
    ];
    return GroupCard(child: Column(children: ruled(rows, indent: 36)));
  }
}
