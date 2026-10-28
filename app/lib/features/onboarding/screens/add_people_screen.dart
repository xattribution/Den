import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/pickers/picture_picker.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import 'hub_adoption_panel.dart';
import '../../../design/forms/forms.dart';
import '../../family/family.dart';

/// The short step after creating a family: kids (name, age, look) and a partner with an invite
/// for their phone. Everything here can also be done later in Family.
class AddPeopleScreen extends StatelessWidget {
  const AddPeopleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final members = app.den.members;
    final me = app.me;
    final others = members.where((m) => m.id != me?.id).toList();

    return FormFrame(
      title: 'Add people',
      back: false,
      bottom: SizedBox(
        width: double.infinity,
        child: others.isEmpty
            ? OutlinedButton(onPressed: () => context.go('/today'), child: const Text('Skip for now'))
            : FilledButton(onPressed: () => context.go('/today'), child: const Text('Go to Today')),
      ),
      children: [
        const HubAdoptionPanel(),
        const SizedBox(height: Sp.s),
        for (final m in members)
          ListTile(
            leading: DenAvatar(m, size: 40),
            title: Text(m.id == me?.id ? '${m.name} (you)' : m.name),
            subtitle: Text(FamilyWords.memberLine(m, app.today)),
            trailing: m.isParent && m.id != me?.id
                ? TextButton(onPressed: () => _invite(context, m), child: Text('Invite ${m.name}'))
                : null,
          ),
        FormBlock(
          child: Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              OutlinedButton.icon(
                onPressed: () => _add(context, kid: true),
                icon: const Icon(PhosphorIconsBold.plus, size: 16),
                label: const Text('Add a kid'),
              ),
              OutlinedButton.icon(
                onPressed: () => _add(context, kid: false),
                icon: const Icon(PhosphorIconsBold.plus, size: 16),
                label: const Text('Add your partner'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _add(BuildContext context, {required bool kid}) async {
    final member = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _QuickPerson(kid: kid),
    );
    if (member == null || kid || !context.mounted) return;
    final m = context.den.member(member);
    if (m != null) await _invite(context, m);
  }

  Future<void> _invite(BuildContext context, Member m) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: Sp.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.s),
              child: Text('Add ${FamilyWords.possessive(m.name)} phone', style: sheet.type.title(sheet.colors.ink)),
            ),
            InvitePanel(qrSize: 240, memberId: m.id),
          ],
        ),
      ),
    ),
  );
}

/// A kid (name, age, age group, look) or a partner (name, look), added in one sheet.
class _QuickPerson extends StatefulWidget {
  const _QuickPerson({required this.kid});
  final bool kid;

  @override
  State<_QuickPerson> createState() => _QuickPersonState();
}

class _QuickPersonState extends State<_QuickPerson> {
  final _name = TextEditingController();
  int _age = 7;
  Tier _tier = FamilyWords.tierForAge(7);
  bool _tierChosen = false;
  late Marker _marker;
  late String _picture;
  bool _ready = false;
  bool _tried = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final look = freshLook(context.den.members);
    _marker = look.$1;
    _picture = look.$2;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _setAge(int age) => setState(() {
    _age = age.clamp(0, 17);
    if (!_tierChosen) _tier = FamilyWords.tierForAge(_age);
  });

  Future<void> _save() async {
    setState(() => _tried = true);
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final result = await perform(
      context,
      () => context.familyActions.addPerson(
        name: name,
        role: widget.kid ? Role.kid : Role.parent,
        tier: widget.kid ? _tier : null,
        marker: _marker,
        picture: _picture,
      ),
    );
    final id = (result?.data['member'] as Map?)?['id'] as String?;
    if (result != null && mounted) Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final name = _name.text.trim();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.kid ? 'Add a kid' : 'Add your partner', style: context.type.title(c.ink)),
              const SizedBox(height: Sp.l),
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Name',
                  errorText: _tried && name.isEmpty ? 'Add a name.' : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (widget.kid) ...[
                const SizedBox(height: Sp.l),
                const FieldLabel.quiet('Age'),
                Row(
                  children: [
                    IconButton.outlined(
                      tooltip: 'Younger',
                      onPressed: _age > 0 ? () => _setAge(_age - 1) : null,
                      icon: const Icon(PhosphorIconsBold.minus, size: 18),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text('$_age', textAlign: TextAlign.center, style: context.type.title(c.ink)),
                    ),
                    IconButton.outlined(
                      tooltip: 'Older',
                      onPressed: _age < 17 ? () => _setAge(_age + 1) : null,
                      icon: const Icon(PhosphorIconsBold.plus, size: 18),
                    ),
                  ],
                ),
                const SizedBox(height: Sp.l),
                const FieldLabel.quiet(
                  'Age group',
                  info:
                      'Pre-readers and little kids get the picture-first kids\' app. Big kids and teens use the regular app.',
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Segmented<Tier>(
                    options: {for (final t in Tier.values) t: FamilyWords.tier(t)},
                    value: _tier,
                    onChanged: (t) => setState(() {
                      _tier = t;
                      _tierChosen = true;
                    }),
                  ),
                ),
              ],
              const SizedBox(height: Sp.l),
              const FieldLabel.quiet('Picture'),
              PicturePicker(
                name: _name.text.trim().isEmpty ? (widget.kid ? 'Kid' : 'Partner') : _name.text.trim(),
                picture: _picture,
                color: _marker,
                takenBy: colorsTaken(context.den.members),
                onPicture: (p) => setState(() => _picture = p),
                onColor: (m) => setState(() => _marker = m),
              ),
              const SizedBox(height: Sp.xl),
              FilledButton(
                onPressed: _save,
                child: Text(name.isEmpty ? (widget.kid ? 'Add kid' : 'Add partner') : 'Add $name'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
