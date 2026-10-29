import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/household.dart';
import '../../../app/log_scope.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/web/web_app.dart';
import '../../today/today.dart' show NeedsModel;
import '../state/membership_actions.dart';

/// Paste an invite, on a device already in a family: reads the clipboard and opens joining the
/// family it invites to (`/families/join`) with [router], or answers why it can't (nothing on
/// the clipboard, a group, not an invite). Whether the family is on this server, the join screen
/// asks the server. Call it straight from the tap, so a browser lets it read the clipboard.
Future<String?> pasteAnotherFamily(GoRouter? router, {VoidCallback? before}) async {
  final pasted = await WebApp.paste();
  String? text = pasted.text;
  if (text == null) {
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } on Object {
      text = null;
    }
  }
  switch (PastedInvite.read(text ?? '')) {
    case PasteProblem(:final message):
      return message;
    case final JoinRoute join:
      before?.call();
      router?.push(join.location);
      return null;
  }
}

/// Whether [log]'s family has something waiting for the person in Needs you, for the switcher's
/// dot.
bool needsSomeone(FamilyLog log, int now) => log.den.isApproved && log.state.view(NeedsModel(now)).isNotEmpty;

/// The family switcher (FAMILY-LINKS-PLAN §4.1): each family on this device with its faces and
/// a dot when it has something in Needs you, "All my families", and Paste an invite. Choosing is
/// instant (every family is open already) and the device remembers it. Groups ("Shared with
/// other families", "Start a group") join the list with phase 3.
Future<void> showFamiliesSheet(BuildContext context) {
  final home = Household.read(context);
  if (home == null) return Future.value();
  final router = GoRouter.of(context);
  return showDenSheet<void>(context, closeLabel: 'Close', builder: (sheet) => FamiliesSheet(home: home, router: router));
}

/// The switcher's content; see [showFamiliesSheet].
class FamiliesSheet extends StatefulWidget {
  const FamiliesSheet({super.key, required this.home, this.router, this.web});

  final Household home;

  /// Where Paste an invite goes; null in tests that only look.
  final GoRouter? router;

  /// Reads invites as the web app does (only this server's), for tests; by default on the web.
  final bool? web;

  @override
  State<FamiliesSheet> createState() => _FamiliesSheetState();
}

class _FamiliesSheetState extends State<FamiliesSheet> {
  String? _pasteError;

  void _choose(VoidCallback choose) {
    choose();
    Navigator.of(context).maybePop();
  }

  /// Called straight from the tap, so a browser lets it read the clipboard.
  Future<void> _paste() async {
    final navigator = Navigator.of(context);
    final problem = await pasteAnotherFamily(widget.router, before: navigator.maybePop);
    if (mounted) setState(() => _pasteError = problem);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return ListenableBuilder(
      listenable: widget.home,
      builder: (context, _) {
        final home = widget.home;
        final now = home.active.den.now();
        final families = home.families;
        // Two families of one name: each says which server it is on.
        String? twinOf(FamilyLog log) {
          final name = log.name.trim().toLowerCase();
          if (families.where((l) => l.name.trim().toLowerCase() == name).length < 2) return null;
          final host = Uri.tryParse(log.membership.hub ?? '')?.host;
          return host == null || host.isEmpty ? null : host;
        }
        final rows = <Widget>[
          for (final log in families)
            _FamilyRow(
              log: log,
              server: twinOf(log),
              chosen: !home.showingAll && identical(log, home.active),
              needs: needsSomeone(log, now),
              onTap: () => _choose(() => home.choose(log)),
            ),
          if (home.several)
            _ChoiceRow(
              leading: Icon(PhosphorIconsRegular.stack, size: 24, color: c.ink),
              label: 'All my families',
              detail: 'Today, Calendar and Lists together',
              chosen: home.showingAll,
              onTap: () => _choose(home.chooseAll),
            ),
          // Phase 3 adds "Shared with other families" (the groups) here, each opening its page.
        ];
        // Scrolls when large text makes it taller than the sheet may be.
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.s, DenLayout.headingInset, Sp.l),
                child: Semantics(header: true, child: Text('Your families', style: t.sheetTitle(c.ink))),
              ),
              GroupCard(child: Column(children: ruled(rows, indent: _ChoiceRow.lead + Sp.m))),
              const SizedBox(height: Sp.l),
              GroupCard(
                child: Column(
                  children: ruled([
                    NavRow(
                      icon: PhosphorIconsRegular.clipboardText,
                      label: 'Paste an invite',
                      detail: "From another family's parent",
                      chevron: false,
                      onTap: _paste,
                    ),
                    // Phase 3: "Start a group".
                  ], indent: 36),
                ),
              ),
              if (_pasteError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.m, DenLayout.headingInset, 0),
                  child: Semantics(liveRegion: true, child: Text(_pasteError!, style: t.meta(c.destructive))),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A family in the switcher: up to four of its people's faces, its name, how many people or that
/// a parent hasn't let this device in yet, the Needs-you dot and a check on the one showing.
class _FamilyRow extends StatelessWidget {
  const _FamilyRow({required this.log, required this.chosen, required this.needs, required this.onTap, this.server});

  final FamilyLog log;

  /// The server it is on, said when another family on this device has the same name.
  final String? server;
  final bool chosen;
  final bool needs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final den = log.den;
    final people = den.members;
    final count = log.waiting
        ? 'Waiting for a parent to let this device in'
        : people.length == 1
            ? '1 person'
            : '${people.length} people';
    final detail = server == null ? count : '$count · on $server';
    // The family's faces in the family's own colors.
    final faces = LogScope(
      log: log,
      child: people.isEmpty
          ? SourceTag(label: log.name, color: log.color, size: 32, semantics: false)
          : FaceStack(faces: [for (final m in people.take(3)) DenAvatar(m, size: 20)], size: 20, max: 3),
    );
    return _ChoiceRow(
      leading: faces,
      label: log.name,
      detail: detail,
      chosen: chosen,
      needs: needs,
      onTap: onTap,
    );
  }
}

/// One choice in the switcher: what it is, a line under it, the Needs-you dot and a check.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.leading,
    required this.label,
    required this.chosen,
    required this.onTap,
    this.detail,
    this.needs = false,
  });

  final Widget leading;
  final String label;
  final String? detail;
  final bool chosen;
  final bool needs;
  final VoidCallback onTap;

  /// The room for the faces before the name: three 20 pt faces, overlapping.
  static const double lead = 56;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final words = [label, ?detail, if (needs) 'Needs you'].join('. ');
    return Semantics(
      button: true,
      selected: chosen,
      label: words,
      excludeSemantics: true,
      child: DenPressable(
        onTap: onTap,
        scale: false,
        shape: const RoundedRectangleBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.m),
            child: Row(
              children: [
                SizedBox(width: lead, child: Align(alignment: Alignment.centerLeft, child: leading)),
                const SizedBox(width: Sp.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: t.rowTitle(c.ink)),
                      if (detail != null) ...[const SizedBox(height: 2), Text(detail!, style: t.meta(c.ink2))],
                    ],
                  ),
                ),
                if (needs) ...[
                  const SizedBox(width: Sp.s),
                  const NeedsDot(),
                ],
                SizedBox(
                  width: 36,
                  child: chosen ? Icon(PhosphorIconsBold.check, size: 20, color: c.ink) : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small ink dot: this family has something waiting in Needs you.
class NeedsDot extends StatelessWidget {
  const NeedsDot({super.key, this.size = 9});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: DecoratedBox(decoration: BoxDecoration(color: context.colors.ink, shape: BoxShape.circle)),
      );
}

/// The family the device shows, at the top of Today on a phone ("Kotvas ▾", or "All my
/// families ▾"), and as the sidebar's title on iPad ([large]). Only on a device in several
/// families; it opens the switcher. A dot says another family has something in Needs you.
class FamilySwitch extends StatelessWidget {
  const FamilySwitch({super.key, this.large = false});

  /// The sidebar's title size.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final home = Household.maybeOf(context);
    if (home == null || !home.several) return const SizedBox.shrink();
    // The dot follows what every family needs, not only the one showing.
    return ListenableBuilder(
      listenable: Listenable.merge([for (final l in home.families) l.state]),
      builder: (context, _) => _switch(context, home),
    );
  }

  Widget _switch(BuildContext context, Household home) {
    final c = context.colors;
    final t = context.text;
    final all = home.showingAll;
    final label = all ? 'All my families' : home.active.name;
    final now = home.active.den.now();
    final elsewhere = home.families.any((l) => (all || !identical(l, home.active)) && needsSomeone(l, now));
    final style = large ? t.sheetTitle(c.ink).copyWith(fontSize: 22 * t.scale) : t.label(c.ink);
    final mark = all
        ? Icon(PhosphorIconsRegular.stack, size: large ? 24 : 20, color: c.ink)
        : SourceTag(label: label, color: home.active.color, size: large ? 24 : 20, semantics: false);
    return Semantics(
      button: true,
      label: '$label. Switch family${elsewhere ? '. Another family needs you' : ''}',
      excludeSemantics: true,
      child: DenPressable(
        onTap: () => showFamiliesSheet(context),
        scale: false,
        shape: const StadiumBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Targets.adult),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                mark,
                const SizedBox(width: Sp.s),
                Flexible(child: Text(label, style: style, maxLines: 2, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: Sp.xs),
                Icon(PhosphorIconsBold.caretDown, size: large ? 18 : 14, color: c.ink),
                if (elsewhere) ...[const SizedBox(width: Sp.s), const NeedsDot(size: 8)],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
