import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../motion.dart';
import '../tokens.dart';
import '../words.dart';
import 'buttons.dart';

/// A row that asks for one thing: a face (or glyph), one sentence in bold, a detail line, and
/// the one action ("I'll drive", "Approve"). On a phone, and whenever the words need the room,
/// the action sits under the words, lined up with them; with room to spare it sits at the end.
/// The action never squeezes the words, and its label never wraps.
class ActionRow extends StatelessWidget {
  const ActionRow({
    super.key,
    this.leading,
    required this.title,
    this.detail,
    this.action,
    this.onTap,
    this.actionBelow,
  });

  /// A 40 pt face or an ink glyph.
  final Widget? leading;
  final String title;
  final String? detail;

  /// Usually a [FilledButton]; null for a row that only says something.
  final Widget? action;

  /// Opens what the row is about (the event, the list).
  final VoidCallback? onTap;

  /// Forces the action under the words (true) or beside them (false). Null decides by room:
  /// beside from 360 pt wide (a phone's card is 326; an iPad column 390 and up) at up to 135 % text.
  final bool? actionBelow;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final below = actionBelow ?? (constraints.maxWidth < 360 || scale > 1.35);
        final words = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tidy(title), style: t.rowTitle(c.ink)),
            if (detail != null && detail!.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(tidy(detail!), style: t.meta(c.ink2)),
            ],
            if (action != null && below) ...[const SizedBox(height: Sp.m), action!],
          ],
        );
        final row = Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.l),
          child: Row(
            crossAxisAlignment: below ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: Sp.m)],
              Expanded(child: words),
              if (action != null && !below) ...[const SizedBox(width: Sp.m), action!],
            ],
          ),
        );
        if (onTap == null) return MergeSemantics(child: row);
        return DenPressable(onTap: onTap, scale: false, shape: const RoundedRectangleBorder(), child: row);
      },
    );
  }
}

/// What a row became after its action: an ink check, the result in words ("You're driving Leo
/// at 3:30 PM"), and Undo in place. Never a toast.
class DoneRow extends StatelessWidget {
  const DoneRow({super.key, required this.message, this.onUndo});

  final String message;

  /// Null hides Undo (nothing to take back, or it was taken back already).
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      liveRegion: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Row(
          children: [
            Icon(PhosphorIconsBold.check, size: 22, color: c.ink),
            const SizedBox(width: Sp.m),
            Expanded(child: Text(tidy(message), style: context.text.control(c.ink))),
            if (onUndo != null) ...[const SizedBox(width: Sp.s), UndoButton(onTap: onUndo)],
          ],
        ),
      ),
    );
  }
}

/// Swaps [child] for [done] in place when [done] isn't null: the row that asked becomes what
/// it did, with Undo, and rows below follow on the UI spring ([DenCrossfade]).
class DoneSwap extends StatelessWidget {
  const DoneSwap({super.key, required this.child, this.done});

  final Widget child;
  final Widget? done;

  @override
  Widget build(BuildContext context) => DenCrossfade(
        child: done == null ? KeyedSubtree(key: const ValueKey('ask'), child: child) : KeyedSubtree(key: const ValueKey('done'), child: done!),
      );
}

/// A row that goes somewhere: an optional ink glyph, a label (and a detail), its current
/// [value] at the end ("Off", "Kid mode"), and a chevron. 56 tall at least. For "Or add one
/// thing", settings and menus.
class NavRow extends StatelessWidget {
  const NavRow({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.detail,
    this.leading,
    this.chevron = true,
    this.value,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;

  /// Instead of [icon]: a face.
  final Widget? leading;
  final String? detail;
  final bool chevron;

  /// What it's set to now, in meta ink2 before the chevron. It wraps rather than being cut off.
  final String? value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final enabled = onTap != null;
    return DenPressable(
      onTap: onTap,
      scale: false,
      shape: const RoundedRectangleBorder(),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.s),
          child: LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: Sp.m)],
                if (icon != null && leading == null) ...[
                  Icon(icon, size: 22, color: enabled ? c.ink : c.ink3),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: t.body(enabled ? c.ink : c.ink3)),
                      if (detail != null) Text(tidy(detail!), style: t.meta(c.ink2)),
                    ],
                  ),
                ),
                if (value != null) ...[
                  const SizedBox(width: Sp.s),
                  // At the end beside the chevron, never more than half the row: a long value
                  // wraps there instead of squeezing the label.
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth / 2),
                    child: Text(value!, style: t.meta(c.ink2), textAlign: TextAlign.end),
                  ),
                ],
                if (chevron) ...[
                  const SizedBox(width: Sp.s),
                  Icon(PhosphorIconsBold.caretRight, size: 18, color: c.ink3),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Faces overlapping a little, each in a ring of the card color: who an event is for.
class FaceStack extends StatelessWidget {
  const FaceStack({super.key, required this.faces, this.size = 26, this.ring = 2, this.max = 4});

  /// Each one [size] across (a [DenAvatar]).
  final List<Widget> faces;
  final double size;
  final double ring;

  /// More than this shows the first ones only.
  final int max;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final shown = faces.take(max).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    final outer = size + ring * 2;
    final step = size - 6;
    return ExcludeSemantics(
      child: SizedBox(
        width: outer + step * (shown.length - 1),
        height: outer,
        child: Stack(
          children: [
            for (final (i, face) in shown.indexed)
              Positioned(
                left: step * i,
                top: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c.card, width: ring)),
                  child: Padding(padding: EdgeInsets.all(ring), child: SizedBox.square(dimension: size, child: face)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
