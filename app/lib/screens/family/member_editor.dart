import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../design/parts/family_frame.dart';
import '../../design/parts/family_pattern_pad.dart';
import '../../design/parts/family_pickers.dart';
import '../../design/parts/family_pin_pad.dart';
import '../../design/parts/family_words.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';

/// One person: name, role, age group, look, permissions, shared-screen sign-in and privacy.
/// A new person is added with one button; an existing person's changes save as they're made.
class MemberEditor extends StatefulWidget {
  const MemberEditor({super.key, this.memberId, this.role});

  /// Null adds a new person.
  final String? memberId;

  /// The role a new person starts with (`parent`, `adult`, `kid`, `guest`).
  final String? role;

  @override
  State<MemberEditor> createState() => _MemberEditorState();
}

class _MemberEditorState extends State<MemberEditor> {
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  late Role _role;
  Tier _tier = Tier.big;
  bool _tierChosen = false;
  late Animal _animal;
  late Marker _marker;
  String? _birthday;
  Set<Grant> _grants = {};
  bool _tried = false;
  bool _ready = false;

  Member? get _member => widget.memberId == null ? null : DenScope.read(context).den.member(widget.memberId!);
  bool get _isNew => widget.memberId == null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final m = _member;
    if (m != null) {
      _name.text = m.name;
      _role = m.role;
      _tier = m.tier ?? Tier.big;
      _tierChosen = m.tier != null;
      _animal = m.animal;
      _marker = m.marker;
      _birthday = m.birthday;
      _grants = {...m.grants};
    } else {
      final look = freshLook(context.den.members);
      _role = Role.values.firstWhere((r) => r.name == widget.role, orElse: () => Role.kid);
      _marker = look.$1;
      _animal = look.$2;
    }
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) _saveName();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  /// Saves a field of an existing person at once; a new person keeps it until "Add". The name
  /// saves when its field loses focus, which can happen as the page closes: this reads the engine
  /// without depending on it, and only while the page is still here.
  void _patch(Map<String, Object?> patch) {
    if (_isNew || !mounted) return;
    final den = DenScope.read(context).den;
    attempt(context, () => den.updateMember(widget.memberId!, patch));
  }

  void _saveName() {
    if (!mounted) return;
    final name = _name.text.trim();
    if (_isNew || name.isEmpty || name == _member?.name) return;
    _patch({'name': name});
  }

  Tier? get _suggested {
    final age = FamilyWords.ageOn(_birthday, context.app.today);
    return age == null ? null : FamilyWords.tierForAge(age);
  }

  /// A role change says what it means and waits for a yes before it's saved.
  Future<void> _setRole(Role r) async {
    if (r == _role) return;
    final m = _member;
    if (m != null) {
      final c = context.colors;
      final yes = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('Make ${m.name} ${FamilyWords.aRole(r)}?'),
          content: Text(FamilyWords.roleChange(m.name, r), style: dialog.type.body(c.ink)),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text('Make ${m.name} ${FamilyWords.aRole(r)}'),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    }
    setState(() => _role = r);
    _patch({'role': r.name, 'tier': r == Role.kid ? _tier.name : null});
  }

  void _setTier(Tier t) {
    setState(() {
      _tier = t;
      _tierChosen = true;
    });
    _patch({'tier': t.name});
  }

  Future<void> _pickBirthday() async {
    final today = context.app.formats.dateTime(context.app.today);
    final current = _birthday == null ? null : context.app.formats.dateTime(_birthday!);
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime(today.year - 8, today.month, today.day),
      firstDate: DateTime(1900),
      lastDate: today,
      helpText: 'Birthday',
    );
    if (picked == null || !mounted) return;
    final date = DateFormat('yyyy-MM-dd').format(picked);
    setState(() => _birthday = date);
    final patch = <String, Object?>{'birthday': date};
    final suggested = _suggested;
    if (_role == Role.kid && !_tierChosen && suggested != null) {
      setState(() => _tier = suggested);
      patch['tier'] = suggested.name;
    }
    _patch(patch);
  }

  void _setGrant(Grant g, bool on) {
    setState(() => on ? _grants.add(g) : _grants.remove(g));
    _patch({
      'grants': [
        for (final x in Grant.values)
          if (_grants.contains(x)) x.name,
      ],
    });
  }

  Future<void> _add() async {
    setState(() => _tried = true);
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final den = context.den;
    String? id;
    final ok = await attempt(context, () async {
      id = await den.addMember(
        name: name,
        role: _role,
        tier: _role == Role.kid ? _tier : null,
        marker: _marker,
        animal: _animal,
        birthday: _birthday,
        grants: _role == Role.kid ? _grants : const {},
      );
    });
    if (ok && mounted && id != null) context.pushReplacement('/family/member/$id');
  }

  Future<void> _remove() async {
    final m = _member!;
    final c = context.colors;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Remove ${m.name} from the family?'),
        content: Text("${FamilyWords.possessive(m.name)} devices stop syncing. This can't be undone."),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.bad, foregroundColor: c.paper),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text('Remove ${m.name}'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await attempt(context, () => context.den.removeMember(m.id));
    if (ok && mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final c = context.colors;
    final member = _member;
    if (!_isNew && member == null) {
      return const FormFrame(
        title: 'Person',
        children: [EmptyLine(message: 'This person is no longer in the family.')],
      );
    }
    final isMe = member != null && member.id == app.me?.id;
    final suggested = _suggested;
    final age = FamilyWords.ageOn(_birthday, app.today);
    final f = DateFormat.yMMMMd();

    return FormFrame(
      title: _isNew ? 'Add person' : member!.name,
      bottom: _isNew
          ? SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _add,
                child: Text(_name.text.trim().isEmpty ? 'Add person' : 'Add ${_name.text.trim()}'),
              ),
            )
          : null,
      children: [
        FormBlock(
          child: TextField(
            controller: _name,
            focusNode: _nameFocus,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Name',
              errorText: _tried && _name.text.trim().isEmpty ? 'Add a name.' : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _saveName(),
          ),
        ),
        FormBlock(
          child: const FieldLabel(
            'Role',
            info:
                'Parents manage the family and devices. Adults add and change plans, chores and lists. '
                'Kids do their own chores. Guests, like a sitter, see plans and check off chores.',
          ),
        ),
        FormBlock(
          top: 0,
          child: _Scroll(
            Segmented<Role>(
              options: {for (final r in Role.values) r: FamilyWords.role(r)},
              value: _role,
              onChanged: isMe ? (_) {} : _setRole,
            ),
          ),
        ),
        if (_role == Role.kid) ...[
          FormBlock(
            child: FieldLabel(
              'Age group',
              info:
                  'Pre-readers and little kids get the picture-first kids\' app. Big kids and teens use the regular app.',
              trailing: suggested != null && suggested != _tier
                  ? Text('Suggested for age $age: ${FamilyWords.tier(suggested)}', style: context.type.meta(c.ink2))
                  : null,
            ),
          ),
          FormBlock(
            top: 0,
            child: _Scroll(
              Segmented<Tier>(
                options: {for (final t in Tier.values) t: FamilyWords.tier(t)},
                value: _tier,
                onChanged: _setTier,
              ),
            ),
          ),
        ],
        FormBlock(child: const FieldLabel('Birthday')),
        FormBlock(
          top: 0,
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _pickBirthday,
              child: Text(_birthday == null ? 'Add birthday' : f.format(app.formats.dateTime(_birthday!))),
            ),
          ),
        ),
        FormBlock(child: const FieldLabel('Animal')),
        FormBlock(
          top: 0,
          child: AnimalPicker(
            value: _animal,
            marker: _marker,
            onChanged: (a) {
              setState(() => _animal = a);
              _patch({'animal': a.name});
            },
          ),
        ),
        FormBlock(child: const FieldLabel('Marker', info: 'The color that means this person everywhere in Den.')),
        FormBlock(
          top: 0,
          child: MarkerPicker(
            value: _marker,
            takenBy: markersTaken(den.members, except: widget.memberId),
            onChanged: (m) {
              setState(() => _marker = m);
              _patch({'marker': m.name});
            },
          ),
        ),
        if (_role == Role.kid) ...[
          const SectionHeader('Permissions'),
          // "Manage points" isn't offered: points are for parents to give. A kid who still has it
          // shows it, so a parent can turn it off.
          for (final g in Grant.values)
            if (g != Grant.points || _grants.contains(g))
              SwitchListTile(
                title: Text(FamilyWords.grant(g)),
                value: _grants.contains(g),
                onChanged: (v) => _setGrant(g, v),
              ),
        ],
        if (member != null) ...[
          _SignInSection(member: member),
          if (member.role != Role.parent) _OversightRow(member: member),
          if (!isMe) ...[
            const SizedBox(height: Sp.xl),
            FormBlock(
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.bad,
                    side: BorderSide(color: c.bad),
                  ),
                  onPressed: _remove,
                  child: Text('Remove ${member.name}'),
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _Scroll extends StatelessWidget {
  const _Scroll(this.child);
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: child),
  );
}

/// Sets how [member] signs in on shared screens: `none`, or a PIN or picture pattern chosen twice.
Future<void> chooseSignIn(BuildContext context, Member member, String kind) async {
  final den = DenScope.read(context).den;
  if (kind == 'none') {
    await attempt(context, () => den.setSignIn(member.id, kind: 'none'));
    return;
  }
  final secret = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: _ChooseSecret(member: member, kind: kind),
    ),
  );
  if (secret == null || !context.mounted) return;
  await attempt(context, () => den.setSignIn(member.id, kind: kind, secret: secret));
}

/// After a parent makes a device a shared display: a parent with no PIN or pattern can't act on
/// one, so anyone at it can't act as them either. Offers to set a PIN now.
Future<void> askParentForSignIn(BuildContext context, String displayName) async {
  final me = DenScope.read(context).me;
  if (me == null || !me.isParent || me.signIn.kind != 'none') return;
  final yes = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Set your PIN for shared screens'),
      content: Text(
        'Shared screens ask a parent for a PIN, so nobody at $displayName can act as you. '
        'Set yours to approve and change things there.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.of(dialog).pop(true), child: const Text('Set a PIN')),
      ],
    ),
  );
  if (yes != true || !context.mounted) return;
  await chooseSignIn(context, me, 'pin');
}

/// How a person proves who they are on the wall or a shared tablet.
class _SignInSection extends StatelessWidget {
  const _SignInSection({required this.member});
  final Member member;

  Future<void> _set(BuildContext context, String kind) => chooseSignIn(context, member, kind);

  @override
  Widget build(BuildContext context) {
    final kind = member.signIn.kind;
    final needed = member.isParent &&
        kind == 'none' &&
        context.den.devices.any((d) => d.mode == DeviceMode.shared && d.approved && !d.revoked);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader('Shared screens'),
        FormBlock(
          top: 0,
          child: FieldLabel(
            'Sign-in',
            info:
                'How ${member.name} shows it\'s them on the wall display or a shared tablet before checking things off.',
          ),
        ),
        FormBlock(
          top: 0,
          child: _Scroll(
            Segmented<String>(
              options: const {'none': 'None', 'pin': '4-digit PIN', 'pattern': 'Picture pattern'},
              value: kind,
              onChanged: (k) => _set(context, k),
            ),
          ),
        ),
        if (needed)
          FormBlock(
            top: Sp.s,
            child: AttentionLine(message: '${member.name} needs a PIN or pattern to act on a shared display.'),
          ),
        if (kind == 'pin' || kind == 'pattern')
          FormBlock(
            top: Sp.s,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => _set(context, kind),
                child: Text(kind == 'pin' ? 'Change PIN' : 'Change pattern'),
              ),
            ),
          ),
      ],
    );
  }
}

/// Choosing a PIN or pattern: enter it, then enter it again.
class _ChooseSecret extends StatefulWidget {
  const _ChooseSecret({required this.member, required this.kind});
  final Member member;
  final String kind;

  @override
  State<_ChooseSecret> createState() => _ChooseSecretState();
}

class _ChooseSecretState extends State<_ChooseSecret> {
  String? _first;
  String? _error;
  int _round = 0;

  void _entered(String secret) {
    if (_first == null) {
      setState(() {
        _first = secret;
        _error = null;
        _round++;
      });
      return;
    }
    if (secret == _first) {
      Navigator.of(context).pop(secret);
      return;
    }
    setState(() {
      _first = null;
      _round++;
      _error = widget.kind == 'pin'
          ? "Those PINs didn't match. Choose one again."
          : "Those patterns didn't match. Choose one again.";
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final name = FamilyWords.possessive(widget.member.name);
    final what = widget.kind == 'pin' ? 'PIN' : 'pattern';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(_first == null ? 'Choose $name $what' : 'Enter it again', style: context.type.title(c.ink)),
          ),
          const SizedBox(height: Sp.l),
          if (widget.kind == 'pin')
            PinPad(key: ValueKey(_round), onComplete: _entered)
          else
            PatternPad(key: ValueKey(_round), onComplete: _entered),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Sp.m),
              child: AttentionLine(message: _error!, bad: true),
            ),
        ],
      ),
    );
  }
}

/// The family's oversight policy for this person's "Just me" items.
class _OversightRow extends StatelessWidget {
  const _OversightRow({required this.member});
  final Member member;

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final family = den.family;
    final on = family?.parentsSeePrivate(member.id) ?? true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Privacy'),
        SwitchListTile(
          title: Row(
            children: [
              Flexible(child: Text('Parents can see ${FamilyWords.possessive(member.name)} private items')),
              const InfoTip(
                'Private items are events, chores and lists set to "Just me". When this is off they stay on this person\'s devices only.',
              ),
            ],
          ),
          value: on,
          // Just this person's entry, so two parents changing different people at once both count.
          onChanged: (v) => attempt(
            context,
            () => den.updateFamily({
              'oversight.${member.id}': {'parentsSeePrivate': v},
            }),
          ),
        ),
      ],
    );
  }
}
