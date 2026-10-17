import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../state/app_state.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'family_pattern_pad.dart';
import 'family_pin_pad.dart';
import 'family_words.dart';

/// Asks who is acting on a shared screen: the family's avatars, then that person's PIN or
/// picture pattern, then [Den.actAs] for [window]. Returns the member, or null if dismissed.
/// [likely] puts one person first, such as the owner of the chore being checked.
Future<Member?> showWhoSheet(
  BuildContext context, {
  String title = "Who's doing this?",
  Duration window = const Duration(seconds: 60),
  String? likely,
  Member? start,
}) {
  return showModalBottomSheet<Member>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.xl),
        child: _WhoSheet(title: title, window: window, likely: likely, start: start),
      ),
    ),
  );
}

class _WhoSheet extends StatefulWidget {
  const _WhoSheet({required this.title, required this.window, this.likely, this.start});
  final String title;
  final Duration window;
  final String? likely;

  /// Skips the avatars and goes straight to this person's PIN or pattern.
  final Member? start;

  @override
  State<_WhoSheet> createState() => _WhoSheetState();
}

class _WhoSheetState extends State<_WhoSheet> {
  Member? _chosen;
  String? _error;
  bool _checking = false;
  final _pin = GlobalKey<PinPadState>();
  final _pattern = GlobalKey<PatternPadState>();

  @override
  void initState() {
    super.initState();
    final start = widget.start;
    if (start == null) return;
    _chosen = start;
    if (start.signIn.kind != 'pin' && start.signIn.kind != 'pattern') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _verify(''));
    }
  }

  Future<void> _choose(Member m) async {
    setState(() {
      _chosen = m;
      _error = null;
    });
    if (m.signIn.kind != 'pin' && m.signIn.kind != 'pattern') await _verify('');
  }

  Future<void> _verify(String secret) async {
    final m = _chosen!;
    final den = context.den;
    setState(() => _checking = true);
    final ok = await den.verifySignIn(m.id, secret);
    if (!mounted) return;
    setState(() => _checking = false);
    if (ok) {
      final owner = den.owner;
      if (owner != null && owner.id != m.id) {
        setState(() => _error = 'This is ${FamilyWords.possessive(owner.name)} device, so only ${owner.name} can act here.');
        return;
      }
      try {
        den.actAs(m.id, window: widget.window);
      } on PermissionDenied catch (e) {
        setState(() => _error = e.message);
        return;
      }
      Navigator.of(context).pop(m);
      return;
    }
    setState(() {
      _error = switch (m.signIn.kind) {
        'pin' => "That's not ${FamilyWords.possessive(m.name)} PIN. Try again.",
        'pattern' => "That's not ${FamilyWords.possessive(m.name)} pattern. Try again.",
        _ => '${m.name} has no sign-in for shared screens yet. A parent can add one in Family.',
      };
    });
    _pin.currentState?.clear();
    _pattern.currentState?.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final members = [...context.den.members];
    if (widget.likely != null) {
      final i = members.indexWhere((m) => m.id == widget.likely);
      if (i > 0) members.insert(0, members.removeAt(i));
    }
    final chosen = _chosen;

    if (chosen == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: context.type.title(c.ink)),
          const SizedBox(height: Sp.l),
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [for (final m in members) PersonTile(member: m, onTap: () => _choose(m))],
          ),
        ],
      );
    }

    final kind = chosen.signIn.kind;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Back',
              onPressed: () => setState(() {
                _chosen = null;
                _error = null;
              }),
              icon: const Icon(PhosphorIconsRegular.arrowLeft),
            ),
            const SizedBox(width: Sp.xs),
            DenAvatar(chosen, size: 40),
            const SizedBox(width: Sp.m),
            Expanded(
              child: Text(
                switch (kind) {
                  'pin' => '${FamilyWords.possessive(chosen.name)} PIN',
                  'pattern' => '${FamilyWords.possessive(chosen.name)} pattern',
                  _ => chosen.name,
                },
                style: context.type.title(c.ink),
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.l),
        if (kind == 'pin') PinPad(key: _pin, onComplete: _verify),
        if (kind == 'pattern') PatternPad(key: _pattern, onComplete: _verify, hidden: true),
        if (_checking && kind != 'pin' && kind != 'pattern')
          const Padding(padding: EdgeInsets.all(Sp.xl), child: CircularProgressIndicator()),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: Sp.m),
            child: AttentionLine(message: _error!, bad: true),
          ),
      ],
    );
  }
}

/// A person to pick on a shared screen: a big avatar over their name, a 72-dp-plus target.
class PersonTile extends StatelessWidget {
  const PersonTile({super.key, required this.member, required this.onTap, this.size = 64});

  final Member member;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      label: member.name,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.card),
        onTap: onTap,
        child: SizedBox(
          width: size + Sp.xxxl,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.s),
            child: Column(
              children: [
                DenAvatar(member, size: size),
                const SizedBox(height: Sp.s),
                Text(
                  member.name,
                  style: context.type.title(c.ink),
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
