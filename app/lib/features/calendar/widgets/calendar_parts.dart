import 'package:den_net/den_net.dart' show SyncState;
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/avatar.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../words/block_words.dart';

/// A pill to press: ink (the one primary action of a region) or the card color (Today, Done).
/// 44 tall at least, its label never wraps or truncates, and it answers the finger in the same
/// frame ([DenPressable]).
class CalendarPill extends StatelessWidget {
  const CalendarPill({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.icon,
    this.edge = false,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final IconData? icon;

  /// A 1.5 line edge, for a secondary pill sitting on a card.
  final bool edge;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = onTap != null;
    final fill = !enabled ? c.fill : (primary ? c.primary : c.card);
    final ink = !enabled ? c.ink2 : (primary ? c.onPrimary : c.ink);
    return DenPressable(
      onTap: onTap,
      color: fill,
      shape: StadiumBorder(side: edge ? BorderSide(color: c.line, width: 1.5) : BorderSide.none),
      semanticLabel: semanticLabel ?? label,
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Targets.adult),
          child: Padding(
            padding: EdgeInsets.fromLTRB(icon == null ? Sp.l : Sp.s + 2, Sp.s, Sp.l, Sp.s),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[Icon(icon, size: 20, color: ink), const SizedBox(width: Sp.xs)],
                Text(label, style: context.text.label(ink), maxLines: 1, softWrap: false),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A round 44 button on the card color, with its name for screen readers and on hover: the
/// event page's More, the iPad week's arrows.
class CalendarRoundButton extends StatelessWidget {
  const CalendarRoundButton({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: DenPressable(
        onTap: onTap,
        color: c.card,
        shape: const CircleBorder(),
        semanticLabel: label,
        child: SizedBox.square(dimension: Targets.adult, child: Icon(icon, size: 20, color: onTap == null ? c.ink3 : c.ink)),
      ),
    );
  }
}

/// A row's ink glyph, as tall as the first line of the words beside it and centered on it, so
/// it stays with that line when the words wrap. It grows a little with the text size (up to
/// 140 %), so it still reads beside large words.
class RowGlyph extends StatelessWidget {
  const RowGlyph(this.icon, {super.key, this.size = 22, this.color, this.fontSize = 17, this.lineHeight = 1.25});

  final IconData icon;
  final double size;
  final Color? color;

  /// The size and line height of the first line beside it.
  final double fontSize;
  final double lineHeight;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final glyph = scaler.scale(size).clamp(size, size * 1.4);
    final line = scaler.scale(fontSize * context.text.scale) * lineHeight;
    final top = ((line - glyph) / 2).clamp(0.0, double.infinity);
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Icon(icon, size: glyph, color: color ?? context.colors.ink),
    );
  }
}

/// A title and what goes with it (a Today button), side by side while both fit on one line;
/// at large text the button moves under the title instead of squeezing it.
class TitleRow extends StatelessWidget {
  const TitleRow({super.key, required this.title, this.trailing = const [], this.large = false, this.overline});

  final String title;
  final List<Widget> trailing;
  final bool large;

  /// A small line above the title.
  final String? overline;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final heading = Semantics(
      header: true,
      child: Text(title, style: context.text.screenTitle(c.ink, large: large)),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Sp.m,
        runSpacing: Sp.s,
        children: [
          if (overline == null)
            heading
          else
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Text(overline!, style: context.text.meta(c.ink2)), heading],
            ),
          if (trailing.isNotEmpty)
            Wrap(spacing: Sp.s, runSpacing: Sp.s, crossAxisAlignment: WrapCrossAlignment.center, children: trailing),
        ],
      ),
    );
  }
}

/// The calendar's views as a segmented control: a filled track, the chosen view on a thumb that
/// slides on the UI spring (ink on phones; the card color on iPad, as the family week has it).
/// The labels never wrap: every segment is as wide as the widest label.
class ViewSwitch<T> extends StatefulWidget {
  const ViewSwitch({super.key, required this.options, required this.value, required this.onChanged, this.cardThumb = false});

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final bool cardThumb;

  @override
  State<ViewSwitch<T>> createState() => _ViewSwitchState<T>();
}

class _ViewSwitchState<T> extends State<ViewSwitch<T>> with SingleTickerProviderStateMixin {
  late final AnimationController _thumb = AnimationController.unbounded(vsync: this, value: _index.toDouble());

  int get _index => widget.options.indexWhere((o) => o.$1 == widget.value).clamp(0, widget.options.length - 1);

  @override
  void didUpdateWidget(ViewSwitch<T> old) {
    super.didUpdateWidget(old);
    final target = _index.toDouble();
    if (_thumb.value == target && !_thumb.isAnimating) return;
    if (DenMotion.reduced(context)) {
      _thumb.value = target;
    } else {
      _thumb.springTo(target);
    }
  }

  @override
  void dispose() {
    _thumb.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final scaler = MediaQuery.textScalerOf(context);
    final bold = t.meta(c.ink).bold;
    var widest = 0.0;
    var tallest = 0.0;
    for (final (_, label) in widget.options) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: bold),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      if (painter.height > tallest) tallest = painter.height;
      painter.dispose();
    }
    final height = (tallest + 14).clamp(36.0, double.infinity);
    final thumbColor = widget.cardThumb ? c.card : c.primary;
    final count = widget.options.length;

    return LayoutBuilder(builder: (context, constraints) {
      // Every segment as wide as the widest label with room around it, the room shrinking
      // before any label would have to.
      final room = constraints.maxWidth.isFinite ? (constraints.maxWidth - 8) / count : double.infinity;
      final segment = (widest + 32 > room ? (widest + 12 > room ? widest + 12 : room) : widest + 32).floorToDouble();
      return _track(context, segment, height, thumbColor);
    });
  }

  Widget _track(BuildContext context, double segment, double height, Color thumbColor) {
    final c = context.colors;
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: ShapeDecoration(color: c.fill, shape: const StadiumBorder()),
        child: SizedBox(
          width: segment * widget.options.length,
          height: height,
          child: AnimatedBuilder(
            animation: _thumb,
            builder: (context, _) {
              final at = _thumb.value;
              return Stack(
                children: [
                  Positioned(
                    left: at.clamp(0.0, widget.options.length - 1.0) * segment,
                    top: 0,
                    width: segment,
                    height: height,
                    child: DecoratedBox(decoration: ShapeDecoration(color: thumbColor, shape: const StadiumBorder())),
                  ),
                  Row(
                    children: [
                      for (final (i, (value, label)) in widget.options.indexed)
                        SizedBox(
                          width: segment,
                          height: height,
                          child: _Segment(
                            label: label,
                            selected: i == _index,
                            // How much of the thumb is under this label: its color follows.
                            under: (1 - (at - i).abs()).clamp(0.0, 1.0),
                            cardThumb: widget.cardThumb,
                            onTap: () => widget.onChanged(value),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.label, required this.selected, required this.under, required this.cardThumb, required this.onTap});

  final String label;
  final bool selected;
  final double under;
  final bool cardThumb;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = cardThumb ? c.ink : Color.lerp(c.ink, c.onPrimary, under)!;
    final style = selected ? context.text.meta(color).bold : context.text.meta(color);
    return Semantics(
      selected: selected,
      button: true,
      inMutuallyExclusiveGroup: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(child: Text(label, style: style, maxLines: 1, softWrap: false)),
      ),
    );
  }
}

/// Who to show: everyone, or one person. Each pill carries the person's face (32); the chosen
/// one has an ink edge and a bold name. Scrolls sideways, edge to edge, when the family is big.
class PersonFilters extends StatelessWidget {
  const PersonFilters({super.key, required this.selected, required this.onChanged});

  /// A member id, or null for everyone.
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final people = app.den.members;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          _FilterPill(
            name: 'Everyone',
            selected: selected == null,
            onTap: () => onChanged(null),
            face: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: c.fill, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text(
                'All',
                textScaler: TextScaler.noScaling,
                style: context.text.caption(c.ink).bold.copyWith(fontSize: 13, height: 1),
              ),
            ),
          ),
          for (final m in people) ...[
            const SizedBox(width: Sp.s),
            _FilterPill(
              name: m.name,
              selected: selected == m.id,
              onTap: () => onChanged(selected == m.id ? null : m.id),
              face: DenAvatar(m, size: 32),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({required this.name, required this.selected, required this.onTap, required this.face});

  final String name;
  final bool selected;
  final VoidCallback onTap;
  final Widget face;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DenPressable(
      onTap: onTap,
      color: c.card,
      selected: selected,
      shape: StadiumBorder(side: BorderSide(color: selected ? c.ink : Colors.transparent, width: 1.5)),
      semanticLabel: selected ? 'Showing $name' : 'Show $name',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Targets.adult),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, Sp.l, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                face,
                const SizedBox(width: Sp.s),
                Text(name, style: selected ? context.text.label(c.ink) : context.text.control(c.ink), maxLines: 1, softWrap: false),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a change did, in place, with Undo: an ink check, one sentence, and an underlined Undo.
class UndoLine extends StatelessWidget {
  const UndoLine({super.key, required this.message, required this.onUndo});

  final String message;

  /// Null once there's nothing to take back.
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      liveRegion: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Targets.adult),
        child: Row(
          children: [
            Icon(PhosphorIconsBold.check, size: 20, color: c.ink),
            const SizedBox(width: 10),
            Expanded(child: Text(tidyLine(message), style: context.text.control(c.ink))),
            if (onUndo != null) ...[
              const SizedBox(width: Sp.s),
              Semantics(
                button: true,
                label: 'Undo',
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onUndo,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: Targets.adult, minWidth: Targets.adult),
                    child: Center(
                      child: Text(
                        'Undo',
                        style: context.text.label(c.ink).copyWith(decoration: TextDecoration.underline, decorationColor: c.ink),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A change that didn't go through, next to where it was made: what happened and the way out.
/// Red as the words and the icon, never as a background.
class ErrorLine extends StatelessWidget {
  const ErrorLine({super.key, required this.message, this.actionLabel = 'Try again', this.onAction});

  final String message;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Icon(PhosphorIconsFill.warningOctagon, size: 20, color: c.destructive),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(tidyLine(message), style: context.text.control(c.destructive)),
            ),
          ),
          if (onAction != null) ...[
            const SizedBox(width: Sp.s),
            TextButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ],
      ),
    );
  }
}

/// A plain line about how things stand, with an ink glyph: offline, read-only, no access.
class NoteLine extends StatelessWidget {
  const NoteLine({super.key, required this.message, required this.icon, this.color});

  final String message;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ink = color ?? c.ink2;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 20, color: ink)),
          const SizedBox(width: 10),
          Expanded(child: Text(tidyLine(message), style: context.text.meta(ink))),
        ],
      ),
    );
  }
}

/// Whether this device has a hub to reach and can't reach it right now: changes stay here and
/// reach the family later, and the screen says so.
bool isOffline(AppState app) {
  final network = app.network;
  if (network == null || !network.connecting) return false;
  final state = network.status.state;
  return state == SyncState.offline || state == SyncState.connecting;
}

/// "Offline. Changes stay on this device and reach the family when it's back online."
class OfflineNote extends StatelessWidget {
  const OfflineNote({super.key, this.force});

  /// For screenshots: draw it whatever the network says.
  final bool? force;

  static const String message = 'Offline. Changes stay on this device until it’s back online.';

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final network = app.network;
    Widget line(bool show) => show
        ? const Padding(
            padding: EdgeInsets.fromLTRB(4, Sp.m, 4, 0),
            child: NoteLine(message: message, icon: PhosphorIconsBold.cloudSlash),
          )
        : const SizedBox.shrink();
    if (force != null) return line(force!);
    if (network == null) return line(false);
    return ListenableBuilder(listenable: network, builder: (context, _) => line(isOffline(app)));
  }
}
