import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../motion.dart';
import '../tokens.dart';
import '../words.dart';
import 'buttons.dart';

/// A row that asks for one thing: a face (or glyph), one sentence in bold, a detail line, and
/// the one action ("I'll drive", "Approve"). On a phone, and whenever the words need the room,
/// the action sits under the words, lined up with them; with room to spare it sits at the end.
/// The action never squeezes the words, and its label never wraps.
///
/// A row that asks a yes or no (a reward, a device asking to join) also answers by a swipe: to
/// the right is [onApprove], to the left [onDecline] ([SwipeActions]). [onDecline] is also the
/// small quiet × at the end of the title ([declineButton]), for a row with no other way to say
/// no or not now; a row with no yes has only the swipe left and the ×, which put it off.
class ActionRow extends StatelessWidget {
  const ActionRow({
    super.key,
    this.leading,
    required this.title,
    this.detail,
    this.action,
    this.onTap,
    this.actionBelow,
    this.onApprove,
    this.approveLabel = 'Approve',
    this.onDecline,
    this.declineLabel = 'Decline',
    this.declineButton = true,
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

  /// A swipe to the right: the yes ([approveLabel], "Approve"), as the row's own button does.
  final VoidCallback? onApprove;
  final String approveLabel;

  /// A swipe to the left, and the ×: the no ("Decline", "Turn away") or, for a row with no no,
  /// "Not now".
  final VoidCallback? onDecline;
  final String declineLabel;

  /// Whether [onDecline] also shows as the ×; false where the row's own buttons already say it
  /// ("Got it", "Remind me later").
  final bool declineButton;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final cross = onDecline != null && declineButton ? DeclineButton(label: declineLabel, onTap: onDecline!) : null;
    final asking = LayoutBuilder(
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
            crossAxisAlignment: below || cross != null ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: Sp.m)],
              Expanded(child: words),
              if (action != null && !below) ...[const SizedBox(width: Sp.m), action!],
              // The × sits on the title's line, its 44 pt target reaching into the row's padding.
              if (cross != null) ...[
                const SizedBox(width: Sp.xs),
                Transform.translate(offset: const Offset(0, -12), child: cross),
              ],
            ],
          ),
        );
        if (onTap == null) return MergeSemantics(child: row);
        return DenPressable(onTap: onTap, scale: false, shape: const RoundedRectangleBorder(), child: row);
      },
    );
    if (onApprove == null && onDecline == null) return asking;
    return SwipeActions(
      onRight: onApprove,
      rightLabel: approveLabel,
      onLeft: onDecline,
      leftLabel: declineLabel,
      child: asking,
    );
  }
}

/// The small quiet × that says no, or not now, on a row that asks ([ActionRow.onDecline]): an
/// 18 pt ink3 glyph in a 44 pt target, never a second big button.
class DeclineButton extends StatelessWidget {
  const DeclineButton({super.key, required this.label, required this.onTap});

  /// What it does, for screen readers and a pointer's hover: "Decline", "Not now".
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: DenPressable(
          onTap: onTap,
          shape: const CircleBorder(),
          semanticLabel: label,
          child: SizedBox.square(
            dimension: Targets.adult,
            child: Icon(PhosphorIconsRegular.x, size: 18, color: context.colors.ink3),
          ),
        ),
      );
}

/// A row that also answers by a swipe (DESIGN.md, "Swipe to answer"): to the right for the yes
/// ([onRight], "Approve"), to the left for the no or not now ([onLeft]). The row follows the
/// finger 1:1 over the card; behind it, in ink on the card, the word and glyph of what letting
/// go would do, turning bold once it's far enough. Let go past [DenMotion.dismissFraction] of
/// the row (or flung faster than [DenMotion.dismissVelocity]) and it does that; either way the
/// row springs back on the UI spring, and the caller turns its place into what happened, with
/// Undo. Never the only way to anything: the row's button and its × do the same, and screen
/// readers get both as actions on the row.
class SwipeActions extends StatefulWidget {
  const SwipeActions({super.key, required this.child, this.onRight, this.rightLabel = 'Approve', this.onLeft, this.leftLabel = 'Decline'});

  final Widget child;
  final VoidCallback? onRight;
  final String rightLabel;
  final VoidCallback? onLeft;
  final String leftLabel;

  @override
  State<SwipeActions> createState() => _SwipeActionsState();
}

class _SwipeActionsState extends State<SwipeActions> with SingleTickerProviderStateMixin {
  late final AnimationController _x = AnimationController.unbounded(vsync: this);
  double _drag = 0;
  double _width = 1;
  bool _armed = false;

  @override
  void dispose() {
    _x.dispose();
    super.dispose();
  }

  double get _reach => _width * DenMotion.dismissFraction;

  /// Past the row's width there's nothing more to show: the row slows to a stop.
  double _resist(double d) {
    final limit = _width * 0.6;
    final a = d.abs();
    return a <= limit ? d : d.sign * (limit + (a - limit) * 0.15);
  }

  void _start(DragStartDetails _) {
    _x.stop();
    _drag = _x.value;
  }

  void _update(DragUpdateDetails d) {
    var next = _drag + (d.primaryDelta ?? 0);
    if (next > 0 && widget.onRight == null) next = 0;
    if (next < 0 && widget.onLeft == null) next = 0;
    _drag = next;
    _x.value = _resist(next);
    final armed = _x.value.abs() >= _reach;
    if (armed != _armed) {
      setState(() => _armed = armed);
      if (armed) HapticFeedback.selectionClick();
    }
  }

  void _end(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final x = _x.value;
    final flung = x != 0 && v.sign == x.sign && v.abs() > DenMotion.dismissVelocity;
    final run = _armed || flung ? (x > 0 ? widget.onRight : (x < 0 ? widget.onLeft : null)) : null;
    if (_armed) setState(() => _armed = false);
    _drag = 0;
    if (DenMotion.reduced(context)) {
      _x.value = 0;
    } else {
      _x.springTo(0, velocity: v);
    }
    run?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final actions = <CustomSemanticsAction, VoidCallback>{
      if (widget.onRight != null) CustomSemanticsAction(label: widget.rightLabel): widget.onRight!,
      if (widget.onLeft != null) CustomSemanticsAction(label: widget.leftLabel): widget.onLeft!,
    };
    Widget side(IconData icon, String label, {required bool start}) {
      final style = _armed ? t.label(c.ink) : t.control(c.ink);
      final parts = [Icon(icon, size: 20, color: c.ink), const SizedBox(width: Sp.s), Text(label, style: style, maxLines: 1, softWrap: false)];
      return Row(
        mainAxisAlignment: start ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: start ? parts : parts.reversed.toList(),
      );
    }

    return Semantics(
      customSemanticsActions: actions,
      child: LayoutBuilder(
        builder: (context, box) {
          _width = box.maxWidth.isFinite && box.maxWidth > 0 ? box.maxWidth : 1;
          return GestureDetector(
            onHorizontalDragStart: _start,
            onHorizontalDragUpdate: _update,
            onHorizontalDragEnd: _end,
            onHorizontalDragCancel: () => _end(DragEndDetails(primaryVelocity: 0)),
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _x,
                child: ColoredBox(color: c.card, child: widget.child),
                builder: (context, row) {
                  final x = _x.value;
                  final shown = (x.abs() / _reach).clamp(0.0, 1.0);
                  return Stack(
                    children: [
                      if (x != 0)
                        Positioned.fill(
                          child: ExcludeSemantics(
                            child: Opacity(
                              opacity: shown,
                              child: x > 0
                                  ? side(PhosphorIconsBold.check, widget.rightLabel, start: true)
                                  : side(PhosphorIconsBold.x, widget.leftLabel, start: false),
                            ),
                          ),
                        ),
                      Transform.translate(offset: Offset(x, 0), child: row),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
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

/// One fact on a detail page, inside a card: the [label] in quiet meta and its value. Side by
/// side with the label in a 112 pt column; one over the other on a narrow card or past 135 %
/// text. 48 tall at least.
class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.child});

  /// The value as plain words.
  InfoRow.text({super.key, required this.label, required String value}) : child = _InfoText(value);

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return MergeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.m),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final scale = MediaQuery.textScalerOf(context).scale(1);
              final label = Text(this.label, style: t.meta(c.ink2));
              if (constraints.maxWidth < 360 || scale > 1.35) {
                // Full width, so the words start at the card's edge rather than being centred.
                return SizedBox(
                  width: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [label, const SizedBox(height: 2), child],
                  ),
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 112, child: Padding(padding: const EdgeInsets.only(top: 2), child: label)),
                  const SizedBox(width: Sp.m),
                  Expanded(child: child),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _InfoText extends StatelessWidget {
  const _InfoText(this.value);

  final String value;

  @override
  Widget build(BuildContext context) => Text(tidy(value), style: context.text.body(context.colors.ink));
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
                  child: LayoutBuilder(
                    builder: (context, room) {
                      final labelStyle = t.body(enabled ? c.ink : c.ink3);
                      final words = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label, style: labelStyle),
                          if (detail != null) Text(tidy(detail!), style: t.meta(c.ink2)),
                        ],
                      );
                      final shown = value;
                      if (shown == null) return words;
                      // At the end beside the chevron, never more than half the row: a long value
                      // wraps there instead of squeezing the label. Where even that would leave
                      // the label's longest word no room (large text), the value goes under it
                      // rather than breaking the word ("Birthd ay").
                      final scaler = MediaQuery.textScalerOf(context);
                      double width(String text, TextStyle style) {
                        final painter = TextPainter(
                          text: TextSpan(text: text, style: style),
                          textDirection: TextDirection.ltr,
                          textScaler: scaler,
                          maxLines: 1,
                        )..layout();
                        final w = painter.width;
                        painter.dispose();
                        return w;
                      }
                      final valueWidth = math.min(width(shown, t.meta(c.ink2)), box.maxWidth / 2);
                      final longest = label.split(RegExp(r'\s+')).map((w) => width(w, labelStyle)).fold(0.0, math.max);
                      if (longest + Sp.s + valueWidth > room.maxWidth) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [words, Text(shown, style: t.meta(c.ink2))],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: words),
                          const SizedBox(width: Sp.s),
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: box.maxWidth / 2),
                            child: Text(shown, style: t.meta(c.ink2), textAlign: TextAlign.end),
                          ),
                        ],
                      );
                    },
                  ),
                ),
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
