import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../state/ask_access.dart';
import '../state/ask_request.dart';
import '../state/helper_link.dart';
import '../words/assistant_words.dart';

/// The ways into Ask besides Add's words (DESIGN.md, "AI helper"): a wide pill at the top of
/// Today, a place in the iPad's sidebar, a row in Add, and ⌘K. Each shows only what
/// [askEntryOf] allows: Ask while the helper is on for the person, a parent's quiet way to set it
/// up while it's off, and nothing otherwise.

/// What [app]'s person gets here: [AskEntry.open], [AskEntry.setUp] or [AskEntry.hidden].
AskEntry askEntryOf(BuildContext context, AppState app) => askEntry(app, linked: Assistant.linkFor(context, app) != null);

/// Opens Ask with nothing to send, showing the conversation as it was. [focus] puts the keyboard
/// in the field (⌘K). Nothing happens when Ask is already showing.
void openAsk(BuildContext context, {bool focus = false}) {
  final router = GoRouter.of(context);
  if (router.state.uri.path == '/ask') return;
  router.push('/ask', extra: AskRequest.open(focus: focus));
}

/// The speech bubble Ask goes by: never a sparkle (ANTI-SLOP 13).
const IconData askIcon = PhosphorIconsRegular.chatCircle;
const IconData askIconBold = PhosphorIconsBold.chatCircle;

/// Today's way into Ask, under the greeting while the helper is on for the person: a wide pill
/// on the card color with the speech bubble and "Ask about your day", 52 tall. Nothing
/// otherwise; a parent's way to set it up is [AskSetUpLine], at the end of the page.
class AskTodayEntry extends StatelessWidget {
  const AskTodayEntry({super.key, this.padding = EdgeInsets.zero});

  /// Around the pill, when it shows.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    if (askEntryOf(context, app) != AskEntry.open) return const SizedBox.shrink();
    final c = context.colors;
    return Padding(
      padding: padding,
      child: DenPressable(
        onTap: () => openAsk(context),
        color: c.card,
        semanticLabel: askTodayLabel,
        child: ExcludeSemantics(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.l + 2, vertical: Sp.s),
              child: Row(
                children: [
                  Icon(askIcon, size: 22, color: c.ink),
                  const SizedBox(width: Sp.m),
                  Expanded(child: Text(askTodayLabel, style: context.text.body(c.ink2))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A parent's quiet way to set the helper up while it's off: one row at the end of Today, "Ask
/// in your own words", to Settings, AI helper, with a quiet "Not now" that puts it away for this
/// person on this device. Only in the family's first weeks ([askSetUpLineShows]); nothing for
/// anyone else, or once it's on.
class AskSetUpLine extends StatelessWidget {
  const AskSetUpLine({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {Changes.notices});
    final me = app.me;
    final linked = Assistant.linkFor(context, app) != null;
    if (me == null || !askSetUpLineShows(app, linked: linked, now: app.den.now())) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: GroupCard(
        child: Row(
          children: [
            Expanded(
              child: NavRow(
                icon: askIcon,
                label: askSetUpLabel,
                detail: askSetUpDetail,
                chevron: false,
                onTap: () => context.push('/settings/assistant'),
              ),
            ),
            const SizedBox(width: Sp.xs),
            TextButton(
              onPressed: () => app.markSeen(askSetUpSeenKey(me.id)),
              child: const Text(askSetUpLater, maxLines: 1, softWrap: false),
            ),
          ],
        ),
      ),
    );
  }
}

/// Add's way into the conversation while the helper is on: "Open Ask", in a card of its own
/// under "Or add one thing". Null otherwise.
Widget? askAddRow(BuildContext context, AppState app, {required VoidCallback onOpen}) {
  if (askEntryOf(context, app) != AskEntry.open) return null;
  return GroupCard(child: NavRow(icon: askIcon, label: askOpenLabel, detail: askOpenDetail, onTap: onOpen));
}

/// The sidebar's "Ask", after Search, while the helper is on for the person; null otherwise.
NavPlace? askPlace(BuildContext context, AppState app) {
  if (askEntryOf(context, app) != AskEntry.open) return null;
  return NavPlace(label: 'Ask', icon: askIcon, selectedIcon: askIconBold, onTap: () => openAsk(context));
}

/// Whether ⌘K (Ctrl+K) opens Ask for [app]'s person: while it's on for them, and for a parent
/// while it's off (Ask then says how to set it up).
bool askShortcutOn(BuildContext context, AppState app) => askEntryOf(context, app) != AskEntry.hidden;
