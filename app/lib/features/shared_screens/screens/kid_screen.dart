import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/pickers/pin_pad.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../state/kids.dart';
import '../state/sign_in_actions.dart';
import '../widgets/sign_in.dart';
import 'kid_home.dart';

/// The kids' screen for pre-readers and little kids ([KidHome]). On a kid's own device it's
/// simply theirs. On a shared screen it starts with "Who's here?" and ends when they tap Done or
/// the sign-in window runs out. Handed over on a parent's phone ([handed]), it stays until the
/// parent's PIN brings the phone back.
class KidScreen extends StatefulWidget {
  const KidScreen({super.key, this.memberId, this.handed = false});

  /// Shows this kid directly; normally the person acting on this device.
  final String? memberId;

  /// A parent handed their phone to the kid: Grown-ups, with the parent's PIN, gives it back.
  final bool handed;

  @override
  State<KidScreen> createState() => _KidScreenState();
}

class _KidScreenState extends State<KidScreen> {
  Timer? _expiry;

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  /// On a shared screen, leaves the kids' screen when the sign-in window ends.
  void _watchWindow(Den den) {
    _expiry?.cancel();
    final until = den.actingUntil;
    if (until == null || !(den.thisDevice?.isShared ?? false)) return;
    final left = until - DateTime.now().millisecondsSinceEpoch;
    _expiry = Timer(Duration(milliseconds: left.clamp(0, 1 << 31)), () {
      if (mounted) _done();
    });
  }

  void _done() {
    context.signInActions.signOut();
    context.go('/today');
  }

  Future<void> _giveBack() async {
    final app = DenScope.read(context);
    final parent = app.me;
    if (parent == null) return;
    if (parent.signIn.kind == 'none') {
      context.go('/today');
      return;
    }
    final ok = await showDenSheet<bool>(context, builder: (_) => _ParentPin(parent: parent));
    if (ok == true && mounted) context.go('/today');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final kid = widget.memberId != null ? den.member(widget.memberId!) : app.me;
    final shared = den.thisDevice?.isShared ?? false;
    if (widget.memberId == null) _watchWindow(den);

    if (kid == null || !kid.isKid || (!widget.handed && !isLittleKid(kid))) {
      return widget.handed ? const _Gone() : _WhoIsHere(onPicked: () => setState(() {}));
    }
    final Widget? action = widget.handed
        ? KidHeaderPill(label: 'Grown-ups', onTap: _giveBack)
        : shared
            ? KidHeaderPill(label: 'Done', onTap: _done)
            : null;
    final home = KidHome(kid: kid, action: action);
    // Handed over, the back gesture doesn't hand the phone back: only the parent's PIN does.
    return widget.handed ? PopScope(canPop: false, child: home) : home;
  }
}

/// The parent's PIN, to take their phone back from a kid.
class _ParentPin extends StatefulWidget {
  const _ParentPin({required this.parent});
  final Member parent;

  @override
  State<_ParentPin> createState() => _ParentPinState();
}

class _ParentPinState extends State<_ParentPin> {
  int _round = 0;
  String? _error;

  Future<void> _check(String secret) async {
    final ok = await context.signInActions.verify(widget.parent.id, secret);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _round++;
        _error = "That's not ${widget.parent.name}'s PIN. Try again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: "${widget.parent.name}'s PIN"),
          Text('So the phone goes back to ${widget.parent.name}, not to a kid.', style: t.body(c.ink)),
          const SizedBox(height: Sp.l),
          Center(child: PinPad(key: ValueKey(_round), onComplete: _check)),
          if (_error != null) ...[
            const SizedBox(height: Sp.m),
            Text(_error!, style: t.meta(c.destructive), textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}

/// A kid who has left the family since the phone was handed over.
class _Gone extends StatelessWidget {
  const _Gone();

  @override
  Widget build(BuildContext context) => DenPage(
        title: 'Den',
        back: false,
        children: [
          EmptyState(message: 'This kid is no longer in the family.', actionLabel: 'Back to Today', onAction: () => context.go('/today')),
        ],
      );
}

/// A shared screen with nobody signed in: the kids' faces, big, to start.
class _WhoIsHere extends StatelessWidget {
  const _WhoIsHere({required this.onPicked});
  final VoidCallback onPicked;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final den = context.den;
    final kids = den.members.where(isLittleKid).toList();
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Sp.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(header: true, child: Text("Who's here?", style: t.screenTitle(c.ink).copyWith(fontSize: 32))),
                const SizedBox(height: Sp.xl),
                Wrap(
                  spacing: Sp.l,
                  runSpacing: Sp.l,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final k in kids)
                      PersonTile(
                        member: k,
                        size: 96,
                        onTap: () async {
                          final who = await showWhoSheet(context, window: const Duration(minutes: 5), start: k);
                          if (who != null) onPicked();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: Sp.xl),
                KidHeaderPill(label: 'Back', onTap: () => context.go('/today')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
