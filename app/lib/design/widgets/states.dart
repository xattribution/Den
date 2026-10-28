import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../tokens.dart';
import '../words.dart';

/// Nothing here yet: one plain line, and the way to add the first thing when there is one.
/// The only centered text on a page.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message, this.actionLabel, this.onAction, this.compact = false});

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Inside a section's card: left-aligned, less room around it.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final action = actionLabel != null && onAction != null
        ? OutlinedButton(onPressed: onAction, child: Text(actionLabel!))
        : null;
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.l),
        child: Wrap(
          spacing: Sp.m,
          runSpacing: Sp.s,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [Text(tidy(message), style: t.body(c.ink2)), ?action],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.xxl, horizontal: Sp.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(tidy(message), style: t.body(c.ink2), textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: Sp.l), action],
        ],
      ),
    );
  }
}

/// Something went wrong: what happened in plain words, and the way out (try again, go back).
/// Red only for the icon and the words, never a background.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, required this.actionLabel, required this.onAction});

  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(PhosphorIconsFill.warningOctagon, size: 20, color: c.destructive),
                ),
                const SizedBox(width: Sp.s),
                Expanded(child: Text(tidy(message), style: context.text.body(c.destructive))),
              ],
            ),
            const SizedBox(height: Sp.m),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

/// A plain line about how things stand, with an ink glyph: "Offline. Changes stay here and
/// sync when you're back." Position and words carry it, not a colored box.
class NoticeLine extends StatelessWidget {
  const NoticeLine({super.key, required this.message, this.icon = PhosphorIconsBold.cloudSlash, this.action});

  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.xs, vertical: Sp.s),
        child: Row(
          children: [
            Icon(icon, size: 20, color: c.ink),
            const SizedBox(width: Sp.s),
            Expanded(child: Text(tidy(message), style: context.text.meta(c.ink))),
            ?action,
          ],
        ),
      ),
    );
  }
}

/// A control that can't be used right now, with why under it ("Only a parent can approve
/// devices"). The control stays visible, dimmed by its own disabled state.
class DisabledReason extends StatelessWidget {
  const DisabledReason({super.key, required this.child, required this.reason, this.disabled = true});

  final Widget child;
  final String reason;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    if (!disabled) return child;
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        const SizedBox(height: Sp.xs),
        Text(tidy(reason), style: context.text.meta(c.ink2)),
      ],
    );
  }
}
