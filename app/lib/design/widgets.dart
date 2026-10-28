import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'pictograms.dart';
import 'tokens.dart';

/// A person: their chosen animal on their marker color.
class DenAvatar extends StatelessWidget {
  const DenAvatar(this.member, {super.key, this.size = 32});

  final Member member;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: member.name,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: c.marker(member.marker), shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Icon(Pictograms.animal(member.animal), size: size * 0.6, color: c.onMarker),
      ),
    );
  }
}

/// The vertical marker bar beside an event or chore: one segment per person it belongs to.
/// Items for everyone show every member's segment.
class PersonBar extends StatelessWidget {
  const PersonBar({super.key, required this.markers, this.width = 4, this.minHeight = 32});

  final List<Marker> markers;
  final double width;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final segments = markers.isEmpty ? [c.rule] : markers.map(c.marker).toList();
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: SizedBox(
        width: width,
        child: Column(
          children: [
            for (final color in segments)
              Expanded(child: Container(width: width, color: color)),
          ],
        ),
      ),
    );
  }
}

/// The round check box of the fridge chart: an empty ring, or solid ink with a check.
/// Done is readable without color: the check mark and the strike-through on the label.
class CheckDot extends StatelessWidget {
  const CheckDot({
    super.key,
    required this.done,
    required this.onChanged,
    this.size = 26,
    this.label,
  });

  final bool done;
  final ValueChanged<bool>? onChanged;
  final double size;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = onChanged != null;
    final target = math.max(size + 16, Targets.adult);
    return Semantics(
      checked: done,
      enabled: enabled,
      label: label,
      button: true,
      child: InkResponse(
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                onChanged!(!done);
              }
            : null,
        radius: target / 2,
        child: SizedBox(
          width: target,
          height: target,
          child: Center(
            child: AnimatedContainer(
              duration: Motion.of(context, Motion.state),
              curve: Motion.curve,
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? c.ink : Colors.transparent,
                border: Border.all(color: done ? c.ink : (enabled ? c.ink2 : c.ink3), width: 2),
              ),
              child: done ? Icon(PhosphorIconsBold.check, size: size * 0.62, color: c.onInk) : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Progress through a chore's steps; turns into a solid check when the last step lands.
class StepRing extends StatelessWidget {
  const StepRing({super.key, required this.done, required this.total, this.size = 26});

  final int done;
  final int total;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final complete = total > 0 && done >= total;
    return Semantics(
      label: '$done of $total steps',
      child: SizedBox(
        width: math.max(size + 16, Targets.adult),
        height: math.max(size + 16, Targets.adult),
        child: Center(
          child: complete
              ? Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(color: c.ink, shape: BoxShape.circle),
                  child: Icon(PhosphorIconsBold.check, size: size * 0.62, color: c.onInk),
                )
              : CustomPaint(
                  size: Size.square(size),
                  painter: _RingPainter(done / math.max(total, 1), c.ink, c.rule),
                  child: SizedBox.square(
                    dimension: size,
                    child: Center(
                      child: Text('$done/$total', style: context.type.meta(c.ink2).copyWith(fontSize: size * 0.34)),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fraction, this.ink, this.track);
  final double fraction;
  final Color ink;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect.deflate(1.25), 0, math.pi * 2, false, stroke..color = track);
    if (fraction > 0) {
      canvas.drawArc(rect.deflate(1.25), -math.pi / 2, math.pi * 2 * fraction, false, stroke..color = ink);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.ink != ink || old.track != track;
}

/// Points: the star sticker shape in star gold with an edge for contrast, and the number.
class StarCount extends StatelessWidget {
  const StarCount(this.points, {super.key, this.size = 16, this.style});

  final int points;
  final double size;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: '$points ${points == 1 ? 'star' : 'stars'}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$points', style: style ?? context.type.meta(c.ink2)),
          const SizedBox(width: 2),
          Star(size: size),
        ],
      ),
    );
  }
}

class Star extends StatelessWidget {
  const Star({super.key, this.size = 16});
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(PhosphorIconsFill.star, size: size, color: c.starEdge),
          Icon(PhosphorIconsFill.star, size: size * 0.78, color: c.star),
        ],
      ),
    );
  }
}

/// A person choice: avatar and name. Selected is a solid ink fill (owner rule O1).
class PersonChip extends StatelessWidget {
  const PersonChip({super.key, required this.member, required this.selected, required this.onTap});

  final Member member;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? c.ink : c.well,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DenAvatar(member, size: 30),
                  const SizedBox(width: Sp.s),
                  Text(member.name, style: context.type.body(selected ? c.onInk : c.ink)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of mutually exclusive choices with a solid selected segment.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.options, required this.value, required this.onChanged});

  final Map<T, String> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: c.well, borderRadius: BorderRadius.circular(Radii.control + 2)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in options.entries)
            Semantics(
              selected: entry.key == value,
              button: true,
              child: Material(
                color: entry.key == value ? c.ink : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.control),
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.control),
                  onTap: () => onChanged(entry.key),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 38, minWidth: 48),
                    padding: const EdgeInsets.symmetric(horizontal: Sp.m),
                    alignment: Alignment.center,
                    child: Text(
                      entry.value,
                      style: entry.key == value ? context.type.bodyStrong(c.onInk) : context.type.body(c.ink2),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A group heading with an optional count or summary on the right. No subtitle (rule O3).
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.action});

  final String title;
  final String? trailing;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xl, Sp.s, Sp.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: Semantics(header: true, child: Text(title, style: context.type.title(c.ink)))),
          if (trailing != null) Text(trailing!, style: context.type.meta(c.ink2)),
          ?action,
        ],
      ),
    );
  }
}

/// The (i) next to a label: help on hover, focus or tap, never printed on the page.
class InfoTip extends StatelessWidget {
  const InfoTip(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: message,
      triggerMode: TooltipTriggerMode.tap,
      child: Focus(
        child: Builder(
          builder: (context) {
            final focused = Focus.of(context).hasFocus;
            return Container(
              width: 18,
              height: 18,
              margin: const EdgeInsets.symmetric(horizontal: Sp.xs),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: focused ? c.ink : c.ink2, width: focused ? 2 : 1),
              ),
              child: Text('i', style: context.type.meta(c.ink2).copyWith(fontSize: 11, fontWeight: FontWeight.w700)),
            );
          },
        ),
      ),
    );
  }
}

/// A state that needs a person: caution (a gap, a conflict, an approval) or bad (late, failed).
/// Always icon plus words; color is never the only signal.
class AttentionLine extends StatelessWidget {
  const AttentionLine({super.key, required this.message, this.bad = false, this.action});

  final String message;
  final bool bad;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = bad ? c.bad : c.caution;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.xs),
      child: Row(
        children: [
          Icon(bad ? PhosphorIconsFill.warningOctagon : PhosphorIconsFill.warning, size: 18, color: color),
          const SizedBox(width: Sp.s),
          Expanded(child: Text(message, style: context.type.body(color))),
          ?action,
        ],
      ),
    );
  }
}

/// An empty state: why it's empty and one thing to do about it.
class EmptyLine extends StatelessWidget {
  const EmptyLine({super.key, required this.message, this.actionLabel, this.onAction});

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.l),
      child: Row(
        children: [
          Expanded(child: Text(message, style: context.type.body(c.ink2))),
          if (actionLabel != null) OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

/// Shows a message with Undo, the way reversible actions confirm themselves.
void showUndo(BuildContext context, String message, VoidCallback onUndo) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      action: SnackBarAction(label: 'Undo', onPressed: onUndo),
      duration: const Duration(seconds: 6),
    ),
  );
}

/// Shows a plain message (errors name the cause and the way out).
void showNote(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 5)));
}

/// What a failed write says when the reason isn't one written for people (storage, say).
const String writeFailedMessage = 'Den couldn’t save that. Try again in a moment.';

/// Runs a write and turns any failure into a note instead of a crash: permission and input
/// errors say why, anything else that it didn't save.
Future<bool> attempt(BuildContext context, Future<void> Function() write) async {
  try {
    await write();
    return true;
  } on PermissionDenied catch (e) {
    if (context.mounted) showNote(context, e.message);
  } on InvalidInput catch (e) {
    if (context.mounted) showNote(context, e.message);
  } on Object catch (e, stack) {
    debugPrint('A write failed: $e\n$stack');
    if (context.mounted) showNote(context, writeFailedMessage);
  }
  return false;
}
