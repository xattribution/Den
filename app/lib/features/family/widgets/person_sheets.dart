import 'dart:typed_data';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/pickers/pattern_pad.dart';
import '../../../design/pickers/picture_picker.dart';
import '../../../design/pickers/pin_pad.dart';
import '../../../design/pictograms.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../../platform/photos/photo_source.dart';
import '../state/family_actions.dart';
import '../state/picture_actions.dart';
import '../state/trust_actions.dart';
import '../words/family_words.dart';
import '../words/oversight.dart';
import '../words/who.dart';

/// The padding inside every Family sheet.
const EdgeInsets sheetPadding = EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.l);

/// "Mia's picture" (AvatarPicker.dc.html): a photo from the camera or the device's photos, the
/// initial or a picture from the pack, and the color, each saved as it's tapped. The color is a
/// parent's to change; a person may change their own picture (a kid when a parent allows it).
Future<void> showPictureSheet(BuildContext context, Member member) =>
    showDenSheet<void>(context, builder: (_) => _PictureSheet(member: member));

class _PictureSheet extends StatefulWidget {
  const _PictureSheet({required this.member});
  final Member member;

  @override
  State<_PictureSheet> createState() => _PictureSheetState();
}

class _PictureSheetState extends State<_PictureSheet> {
  late String _picture = widget.member.picture;
  late Marker _color = widget.member.marker;
  bool _saving = false;

  Future<void> _save({String? picture, Marker? color}) async {
    setState(() {
      _picture = picture ?? _picture;
      _color = color ?? _color;
    });
    if (picture != null) {
      final pictures = context.pictureActions;
      await attempt(context, () => pictures.setPicture(widget.member.id, picture));
    } else {
      final family = context.familyActions;
      await attempt(context, () => family.saveDetails(widget.member.id, marker: color));
    }
  }

  /// Takes or chooses a photo. The picker opens first thing in the tap: a browser opens its
  /// file chooser only from one.
  Future<void> _photo({required bool camera}) async {
    final source = Photos.source;
    final pending = camera ? source.take() : source.choose();
    final den = DenScope.read(context).den;
    final Uint8List? bytes;
    try {
      bytes = await pending;
    } on PhotoProblem catch (e) {
      if (mounted) showNote(context, e.message);
      return;
    }
    if (bytes == null || !mounted) return;
    setState(() => _saving = true);
    final pictures = context.pictureActions;
    final ok = await attempt(context, () => pictures.setPhoto(widget.member.id, bytes!));
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _picture = den.member(widget.member.id)?.picture ?? _picture;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final members = app.den.members;
    final name = widget.member.name;
    final source = Photos.source;
    final colors = app.allows(DenAction.manageFamily);
    return SingleChildScrollView(
      padding: sheetPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: app.me?.id == widget.member.id ? 'Your picture' : '${FamilyWords.possessive(name)} picture', actionLabel: 'Done', primary: true),
          PicturePicker(
            name: name,
            picture: _picture,
            color: _color,
            photo: DenPhotos.of(Picture.photoIdOf(_picture)),
            colorLabel: '${FamilyWords.possessive(name)} color',
            takenBy: colorsTaken(members, except: widget.member.id),
            showColors: colors,
            photoBusy: _saving,
            onCamera: source.canTake ? () => _photo(camera: true) : null,
            onPhotos: source.canChoose ? () => _photo(camera: false) : null,
            onPicture: (p) => _save(picture: p),
            onColor: (m) => _save(color: m),
          ),
        ],
      ),
    );
  }
}

/// Changing someone's name: the field, and Save.
Future<void> showNameSheet(BuildContext context, Member member) =>
    showDenSheet<void>(context, builder: (_) => _NameSheet(member: member));

class _NameSheet extends StatefulWidget {
  const _NameSheet({required this.member});
  final Member member;

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  late final _name = TextEditingController(text: widget.member.name);
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Add a name.');
      return;
    }
    if (name == widget.member.name) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _busy = true);
    final family = context.familyActions;
    final problem = await tryWrite(() => family.saveDetails(widget.member.id, name: name));
    if (!mounted) return;
    if (problem == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = problem;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: sheetPadding.copyWith(bottom: MediaQuery.viewInsetsOf(context).bottom + Sp.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: '${FamilyWords.possessive(widget.member.name)} name'),
          LabeledField(
            label: 'Name',
            error: _error,
            child: TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              style: t.body(c.ink),
              onSubmitted: (_) => _save(),
            ),
          ),
          const SizedBox(height: Sp.l),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
        ],
      ),
    );
  }
}

/// "Who is Maya?": a parent, a grown-up, a sitter, or a kid of an age. Choosing says what will
/// change, and the button names it ("Make Maya a parent"); nothing saves before that.
Future<void> showRoleSheet(BuildContext context, Member member) =>
    showDenSheet<void>(context, builder: (_) => _RoleSheet(member: member));

class _RoleSheet extends StatefulWidget {
  const _RoleSheet({required this.member});
  final Member member;

  @override
  State<_RoleSheet> createState() => _RoleSheetState();
}

class _RoleSheetState extends State<_RoleSheet> {
  late final Who _was = Who.of(widget.member);
  late Who _who = _was;
  bool _busy = false;
  String? _error;

  String get _name => widget.member.name;

  String _verb(Who w) => w.kid
      ? (_was.kid ? 'Save' : 'Make $_name a kid')
      : 'Make $_name ${FamilyWords.aRole(w.role)}';

  String _says(Who w) {
    if (w.kid && _was.kid) return '$_name ${FamilyWords.tierMeans(w.tier!)[0].toLowerCase()}${FamilyWords.tierMeans(w.tier!).substring(1)}';
    final change = FamilyWords.roleChange(_name, w.role);
    if (!w.kid) return change;
    final starts = defaultGrants(w.tier);
    final allowed = [
      if (starts.contains(Grant.lists)) 'add to lists',
      if (starts.contains(Grant.events)) 'add events and chores',
    ];
    return allowed.isEmpty ? change : '$change $_name starts out able to ${FamilyWords.joinAnd(allowed)}.';
  }

  Future<void> _save() async {
    final w = _who;
    setState(() {
      _busy = true;
      _error = null;
    });
    final family = context.familyActions;
    final trust = context.trustActions;
    final problem = await tryWrite(() {
      if (w.role == widget.member.role) return family.saveDetails(widget.member.id, tier: w.tier);
      return trust.setRole(widget.member.id, w.role, tier: w.tier, grants: w.kid ? defaultGrants(w.tier) : null);
    });
    if (!mounted) return;
    if (problem == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = problem;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final changed = _who != _was;
    return SingleChildScrollView(
      padding: sheetPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: 'Who is $_name?'),
          GroupCard(
            child: ChoiceRows<Who>(
              choices: [for (final w in Who.values) Choice(w, w.label)],
              value: _who,
              onChanged: (w) => setState(() {
                _who = w;
                _error = null;
              }),
            ),
          ),
          DenReveal(
            visible: changed,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.l, DenLayout.headingInset, 0),
              child: ConfirmLine(
                message: _says(_who),
                error: _error,
                button: FilledButton(
                  onPressed: _busy || !changed ? null : _save,
                  child: Text(_verb(_who), maxLines: 1, softWrap: false),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A sentence saying what a change will do, an error when it didn't save, and its button.
class ConfirmLine extends StatelessWidget {
  const ConfirmLine({super.key, required this.message, required this.button, this.error});

  final String message;
  final Widget button;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tidy(message), style: t.body(c.ink)),
        if (error != null) ...[
          const SizedBox(height: Sp.s),
          Text(tidy(error!), style: t.meta(c.destructive)),
        ],
        const SizedBox(height: Sp.m),
        button,
      ],
    );
  }
}

/// How [m] signs in on shared screens: what they have, or for someone new a picture pattern for
/// a kid of 8 or under and a PIN for anyone else.
String signInKindFor(Member m) {
  if (m.signIn.kind == 'pin' || m.signIn.kind == 'pattern') return m.signIn.kind;
  return m.isKid && (m.tier == Tier.preReader || m.tier == Tier.little) ? 'pattern' : 'pin';
}

/// Whether someone has their PIN or pattern, in words: "Set", "Not set".
String signInWords(Member m) => m.signIn.kind == 'pin' || m.signIn.kind == 'pattern' ? 'Set' : 'Not set';

/// Sets [member]'s PIN or picture pattern for shared screens, entered twice. [canClear] offers
/// "No PIN" (never to a parent once the family has a shared screen).
Future<void> showSignInSheet(BuildContext context, Member member, {bool canClear = false, SheetWrap? scope}) =>
    showDenSheet<void>(context, scope: scope, builder: (_) => _SignInSheet(member: member, canClear: canClear));

class _SignInSheet extends StatefulWidget {
  const _SignInSheet({required this.member, required this.canClear});
  final Member member;
  final bool canClear;

  @override
  State<_SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends State<_SignInSheet> {
  late final String _kind = signInKindFor(widget.member);
  String? _first;
  String? _error;
  int _round = 0;
  bool _busy = false;

  String get _what => _kind == 'pin' ? 'PIN' : 'pattern';

  Future<void> _set(String kind, {String? secret}) async {
    setState(() => _busy = true);
    final trust = context.trustActions;
    final problem = await tryWrite(() => trust.setSignIn(widget.member.id, kind, secret: secret));
    if (!mounted) return;
    if (problem == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _first = null;
        _round++;
        _error = problem;
      });
    }
  }

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
      _set(_kind, secret: secret);
      return;
    }
    setState(() {
      _first = null;
      _round++;
      _error = "Those ${_what}s didn't match. Choose one again.";
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final name = FamilyWords.possessive(widget.member.name);
    final me = context.watch(const {}).me?.id == widget.member.id;
    return SingleChildScrollView(
      padding: sheetPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: me ? 'Your $_what' : '$name $_what'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
            child: Text(
              _first == null
                  ? (_kind == 'pin' ? 'Choose 4 numbers for shared screens.' : 'Tap 4 pictures in order.')
                  : 'Once more, to be sure.',
              style: t.body(c.ink),
            ),
          ),
          const SizedBox(height: Sp.l),
          Center(
            child: _kind == 'pin'
                ? PinPad(key: ValueKey(_round), onComplete: _busy ? (_) {} : _entered)
                : PatternPad(key: ValueKey(_round), onComplete: _busy ? (_) {} : _entered),
          ),
          if (_error != null) ...[
            const SizedBox(height: Sp.m),
            Text(tidy(_error!), style: t.meta(c.destructive), textAlign: TextAlign.center),
          ],
          if (widget.canClear && widget.member.signIn.kind != 'none') ...[
            const SizedBox(height: Sp.l),
            Center(child: TextButton(onPressed: _busy ? null : () => _set('none'), child: Text('No $_what'))),
          ],
        ],
      ),
    );
  }
}

/// After a parent makes a device a shared display: a parent with no PIN can't act on one, and
/// nobody there can act as them either. Asks for one now.
///
/// [me] and [scope] are the family's where the display was approved, for a [context] that
/// outlived that page (the app's root): the PIN is that family's, never the one the device shows.
Future<void> askParentForSignIn(BuildContext context, String displayName, {Member? me, SheetWrap? scope}) async {
  me ??= DenScope.read(context).me;
  if (me == null || !me.isParent || me.signIn.kind != 'none') return;
  final yes = await showDenSheet<bool>(
    context,
    scope: scope,
    builder: (sheet) {
      final c = sheet.colors;
      return Padding(
        padding: sheetPadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader(title: 'Set your PIN for shared screens', actionLabel: 'Not now'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
              child: Text(
                tidy('$displayName asks a parent for a PIN, so nobody there can act as you. Set yours to '
                    'approve and change things on it.'),
                style: sheet.text.body(c.ink),
              ),
            ),
            const SizedBox(height: Sp.l),
            FilledButton(onPressed: () => Navigator.of(sheet).pop(true), child: const Text('Set a PIN')),
          ],
        ),
      );
    },
  );
  if (yes != true || !context.mounted) return;
  await showSignInSheet(context, me, scope: scope);
}

/// Whose a device is: a person (personal), or nobody's (a shared display or the hub).
class DeviceOwner {
  const DeviceOwner.person(String this.member) : mode = DeviceMode.personal;
  const DeviceOwner.shared(this.mode) : member = null;
  final String? member;
  final DeviceMode mode;
}

/// "Whose is Kitchen iPad?", for a device that joined without naming anyone (a shared display
/// or a hub set up from Advanced). Returns the answer, or null if closed.
Future<DeviceOwner?> showWhoseDeviceSheet(BuildContext context, String deviceName) {
  final den = DenScope.read(context).den;
  return showDenSheet<DeviceOwner>(
    context,
    builder: (sheet) {
      final c = sheet.colors;
      Widget row(Widget leading, String label, DeviceOwner owner, {String? detail}) =>
          NavRow(leading: leading, label: label, detail: detail, chevron: false, onTap: () => Navigator.of(sheet).pop(owner));
      Widget glyph(IconData icon) => SizedBox.square(dimension: 40, child: Icon(icon, size: 26, color: c.ink));
      return SingleChildScrollView(
        padding: sheetPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(title: 'Whose is $deviceName?'),
            GroupCard(
              child: Column(
                children: ruled([
                  for (final m in den.members) row(DenAvatar(m, size: 40), m.name, DeviceOwner.person(m.id)),
                  row(
                    glyph(Pictograms.device(DeviceKind.display)),
                    'Shared display',
                    const DeviceOwner.shared(DeviceMode.shared),
                    detail: 'For everyone, on the counter or the wall',
                  ),
                  row(
                    glyph(Pictograms.device(DeviceKind.hub)),
                    'Hub',
                    const DeviceOwner.shared(DeviceMode.hub),
                    detail: 'Keeps the family in sync',
                  ),
                ], indent: RowRule.afterFace),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Approves a device that named nobody, as someone's, a shared display or the hub. A parent who
/// just made a shared display and has no PIN is asked to set one, since without it they can't
/// act there.
Future<void> approveDevice(BuildContext context, String deviceId, String name) async {
  final owner = await showWhoseDeviceSheet(context, name);
  if (owner == null || !context.mounted) return;
  final trust = context.trustActions;
  // The request leaves the list once approved, so ask from somewhere that stays, carrying this
  // family (its parent, its PIN) rather than the root's, which is the family the device shows.
  final keep = Navigator.of(context, rootNavigator: true).context;
  final me = DenScope.read(context).me;
  final scope = SheetScope.of(context);
  final ok = await attempt(context, () => trust.approveDevice(deviceId, member: owner.member, mode: owner.mode));
  if (!ok || owner.mode != DeviceMode.shared || !keep.mounted) return;
  await askParentForSignIn(keep, name, me: me, scope: scope);
}

/// The glyph for a device: a phone, a tablet, a computer.
IconData deviceGlyph(Device d) => Pictograms.device(d.mode == DeviceMode.shared ? DeviceKind.display : d.kind);

/// A person's ink glyph when there is no face: someone new.
const IconData newPersonGlyph = PhosphorIconsRegular.userPlus;
