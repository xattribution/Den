import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../widgets/sign_in.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/family_routes.dart';
import '../../../app/app_state.dart';
import 'little_kid.dart';
import 'pre_reader.dart';

/// The kids' app for pre-readers and little kids. On a kid's own device it's simply theirs; on a
/// shared screen it starts with "Who's using Den?" and ends when they tap Done or the sign-in
/// window runs out.
class KidScreen extends StatefulWidget {
  const KidScreen({super.key, this.memberId});

  /// Shows this kid directly, for tests; normally the person acting on this device.
  final String? memberId;

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

  /// On a shared screen, leaves the kids' app when the sign-in window ends.
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
    context.den.actAs(null);
    context.go('/today');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final kid = widget.memberId != null ? den.member(widget.memberId!) : app.me;
    final shared = den.thisDevice?.isShared ?? false;
    if (widget.memberId == null) _watchWindow(den);

    if (kid == null || !isLittleKid(kid)) return _WhoIsHere(onPicked: () => setState(() {}));

    final header = KidHeader(kid: kid, onSwitch: shared ? () => _switch(context) : null, onDone: shared ? _done : null);
    return kid.tier == Tier.preReader ? PreReaderApp(kid: kid, header: header) : LittleKidApp(kid: kid, header: header);
  }

  Future<void> _switch(BuildContext context) async {
    final who = await showWhoSheet(context, title: "Who's using Den?", window: const Duration(minutes: 5));
    if (who == null || !context.mounted) return;
    if (isLittleKid(who)) {
      setState(() {});
    } else {
      context.go('/today');
    }
  }
}

/// The kid's avatar and name; on shared screens, Switch person and Done.
class KidHeader extends StatelessWidget {
  const KidHeader({super.key, required this.kid, this.onSwitch, this.onDone});

  final Member kid;
  final VoidCallback? onSwitch;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.s, Sp.s),
      child: Row(
        children: [
          DenAvatar(kid, size: 56),
          const SizedBox(width: Sp.m),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(kid.name, style: context.type.heading(c.ink), overflow: TextOverflow.ellipsis),
            ),
          ),
          if (onSwitch != null)
            SizedBox(
              height: Targets.kid,
              child: TextButton.icon(
                onPressed: onSwitch,
                icon: const Icon(PhosphorIconsRegular.userSwitch, size: 28),
                label: Text('Switch', style: context.type.title(c.ink)),
              ),
            ),
          if (onDone != null)
            SizedBox(
              height: Targets.kid,
              child: TextButton(
                onPressed: onDone,
                child: Text('Done', style: context.type.title(c.ink)),
              ),
            ),
        ],
      ),
    );
  }
}

/// A shared screen with nobody signed in: the kids' avatars, big, to start.
class _WhoIsHere extends StatelessWidget {
  const _WhoIsHere({required this.onPicked});
  final VoidCallback onPicked;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final den = context.den;
    final kids = den.members.where(isLittleKid).toList();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Sp.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Who's here?", style: context.type.heading(c.ink)),
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
                SizedBox(
                  height: Targets.kid,
                  child: TextButton(
                    onPressed: () => context.go('/today'),
                    child: Text('Back', style: context.type.title(c.ink)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
