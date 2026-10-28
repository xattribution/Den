import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/parts/family_pickers.dart';
import '../../design/parts/family_words.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import 'device_parts.dart';

/// The family: devices waiting for approval first, then people in order, then devices by person,
/// then the family's own settings. Parents manage; everyone else sees who's in the family.
class FamilyScreen extends StatelessWidget {
  const FamilyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final manage = app.allows(DenAction.manageFamily);
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final people = [
      SectionHeader(
        'People',
        action: manage
            ? TextButton.icon(
                onPressed: () => context.push('/family/member/new'),
                icon: const Icon(PhosphorIconsBold.plus, size: 16),
                label: const Text('Add person'),
              )
            : null,
      ),
      for (final m in app.den.members) _MemberRow(m, manage: manage),
    ];
    final devices = manage ? _devicesSection(context) : const <Widget>[];
    final settings = manage ? const [_FamilySettings()] : const <Widget>[];

    return Scaffold(
      appBar: AppBar(title: Semantics(header: true, child: Text(manage ? 'Family and devices' : 'Family'))),
      body: SafeArea(
        top: false,
        child: wide
            ? ListView(
                padding: const EdgeInsets.only(bottom: Sp.xxxl),
                children: [
                  const PendingApprovals(),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [...people, ...settings],
                        ),
                      ),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: devices),
                      ),
                    ],
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: Sp.xxxl),
                children: [const PendingApprovals(), ...people, ...devices, ...settings],
              ),
      ),
    );
  }
}

List<Widget> _devicesSection(BuildContext context) => [
  SectionHeader(
    'Devices',
    action: TextButton.icon(
      onPressed: () => context.push('/family/devices/add'),
      icon: const Icon(PhosphorIconsBold.plus, size: 16),
      label: const Text('Add a device'),
    ),
  ),
  ...deviceGroups(context),
];

class _MemberRow extends StatelessWidget {
  const _MemberRow(this.member, {required this.manage});
  final Member member;
  final bool manage;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final isMe = app.me?.id == member.id;
    return ListTile(
      leading: DenAvatar(member, size: 40),
      title: Text(isMe ? '${member.name} (you)' : member.name),
      subtitle: Text(FamilyWords.memberLine(member, app.today)),
      trailing: manage ? Icon(PhosphorIconsRegular.caretRight, size: 18, color: c.ink3) : null,
      onTap: manage ? () => context.push('/family/member/${member.id}') : null,
    );
  }
}

/// The family's name, time zone, first day of the week, and whether it uses points.
class _FamilySettings extends StatefulWidget {
  const _FamilySettings();

  @override
  State<_FamilySettings> createState() => _FamilySettingsState();
}

class _FamilySettingsState extends State<_FamilySettings> {
  late final TextEditingController _name = TextEditingController(text: DenScope.read(context).den.family?.name ?? '');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _saveName();
    });
  }

  /// Also runs when the field loses focus, which can happen as the page closes: it reads the
  /// engine without depending on it, and only while this page is still here.
  void _saveName() {
    if (!mounted) return;
    final den = DenScope.read(context).den;
    final name = _name.text.trim();
    if (name.isEmpty || name == den.family?.name) return;
    attempt(context, () => den.updateFamily({'name': name}));
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final family = den.family;
    if (family == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Family settings'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l),
          child: TextField(
            controller: _name,
            focusNode: _focus,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Family name'),
            onSubmitted: (_) => _saveName(),
          ),
        ),
        const Padding(padding: EdgeInsets.fromLTRB(Sp.l, Sp.l, Sp.l, 0), child: FieldLabel('Time zone')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l),
          child: TimeZoneField(
            value: family.timezone,
            onChanged: (z) => attempt(context, () => den.updateFamily({'timezone': z})),
          ),
        ),
        const Padding(padding: EdgeInsets.fromLTRB(Sp.l, Sp.l, Sp.l, 0), child: FieldLabel('Weeks start on')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Segmented<int>(
              options: const {0: 'Sunday', 1: 'Monday'},
              value: family.weekStart,
              onChanged: (v) => attempt(context, () => den.updateFamily({'weekStart': v})),
            ),
          ),
        ),
        const SizedBox(height: Sp.s),
        SwitchListTile(
          title: const Text('Points and rewards'),
          value: family.pointsEnabled,
          onChanged: (v) => attempt(context, () => den.updateFamily({'pointsEnabled': v})),
        ),
      ],
    );
  }
}
