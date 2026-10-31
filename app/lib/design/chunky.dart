import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';
import 'tokens.dart';

/// Kids mode's press (KIDS_MODE_AND_SOFT_THEME.md, "Elevation" and "Motion"): a chunky shape
/// standing on a solid [lip], [depth] below its [face], like a molded plastic button. On pointer
/// down the face sinks onto its lip on the UI spring (the lip disappears under it) and springs
/// back on release; a drag past the slop lets go. This replaces [DenPressable]'s 0.97 scale on
/// kid tiles only.
///
/// Under Reduce Motion nothing moves: the face shades for 100 ms instead. A tap gives one light
/// haptic ([haptic]; off on the wall, whose screens rarely have one). Keyboard focus draws a 2 px
/// ink ring; Increase Contrast outlines the face in ink. Nothing is translucent: every shade is
/// blended to an opaque color, so Reduce Transparency changes nothing here.
class ChunkyPressable extends StatefulWidget {
  const ChunkyPressable({
    super.key,
    required this.onTap,
    required this.child,
    required this.face,
    required this.lip,
    this.onLongPress,
    this.depth = Lip.tile,
    this.radius = Radii.kidTile,
    this.haptic = true,
    this.semanticLabel,
    this.longPressHint,
    this.toggled,
  });

  final VoidCallback? onTap;

  /// A second way to something, never the only one: on a job tile, hearing it read aloud.
  final VoidCallback? onLongPress;
  final Widget child;
  final Color face;

  /// Decorative: it never carries text.
  final Color lip;

  /// How far the lip sits below the face, and how far a press sinks it: [Lip.tile] (6) on a
  /// phone or tablet, [Lip.card] (4) for a slab, [Lip.wall] (8) on the wall.
  final double depth;
  final double radius;
  final bool haptic;
  final String? semanticLabel;

  /// What a screen reader says a long press does ("Read it to me").
  final String? longPressHint;
  final bool? toggled;

  /// How far the face of the [ChunkyPressable] at [element] has sunk now, for tests.
  @visibleForTesting
  static double sunk(Element element) => (element as StatefulElement).state is _ChunkyPressableState
      ? (element.state as _ChunkyPressableState)._offset
      : 0;

  @override
  State<ChunkyPressable> createState() => _ChunkyPressableState();
}

class _ChunkyPressableState extends State<ChunkyPressable> with TickerProviderStateMixin {
  /// The platform's touch slop: past this a press becomes a scroll.
  static const double _slop = 18;

  /// 0 standing on the lip, 1 sunk onto it. A spring can pass 1 a little; the offset can't.
  late final AnimationController _sink = AnimationController.unbounded(vsync: this);

  /// Reduce Motion's press: a shade that fades in and out in 100 ms.
  late final AnimationController _shade = AnimationController(vsync: this, duration: DenMotion.fade);

  int? _pointer;
  Offset? _downAt;
  bool _pressed = false;
  bool _hovered = false;
  bool _focused = false;
  bool _reduced = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  double get _offset => _sink.value.clamp(0.0, 1.0) * widget.depth;

  @override
  void dispose() {
    _sink.dispose();
    _shade.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    _pressed = pressed;
    if (_reduced) {
      _sink.value = 0;
      pressed ? _shade.forward() : _shade.reverse();
    } else {
      _shade.value = 0;
      _sink.springTo(pressed ? 1 : 0, spring: DenMotion.ui);
    }
  }

  void _down(PointerDownEvent event) {
    if (!_enabled || _pointer != null) return;
    _pointer = event.pointer;
    _downAt = event.position;
    _setPressed(true);
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer || _downAt == null) return;
    if ((event.position - _downAt!).distance > _slop) _setPressed(false);
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _downAt = null;
    _setPressed(false);
  }

  void _tap() {
    if (widget.haptic) HapticFeedback.lightImpact();
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    _reduced = DenMotion.reduced(context);
    final c = context.colors;
    final contrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    final radius = BorderRadius.circular(widget.radius);

    Widget face = AnimatedBuilder(
      animation: Listenable.merge([_sink, _shade]),
      builder: (context, child) {
        final shade = _shade.value * DenMotion.pressShade + (_hovered && _enabled ? DenMotion.hoverShade : 0);
        return Transform.translate(
          offset: Offset(0, _offset),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _shaded(widget.face, shade, c),
              borderRadius: radius,
              border: contrast ? Border.all(color: c.ink, width: 2) : null,
            ),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
    if (_focused) face = CustomPaint(foregroundPainter: _Ring(widget.radius, c.ink), child: face);

    final shape = CustomPaint(
      painter: _LipPainter(widget.lip, widget.radius, widget.depth),
      child: Padding(padding: EdgeInsets.only(bottom: widget.depth), child: face),
    );

    return Semantics(
      container: true,
      button: true,
      enabled: _enabled,
      toggled: widget.toggled,
      label: widget.semanticLabel,
      onLongPressHint: widget.onLongPress == null ? null : widget.longPressHint,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onShowFocusHighlight: (value) {
          if (value != _focused) setState(() => _focused = value);
        },
        onShowHoverHighlight: (value) {
          if (value != _hovered) setState(() => _hovered = value);
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            _tap();
            return null;
          }),
        },
        child: Listener(
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap == null ? null : _tap,
            onLongPress: widget.onLongPress,
            child: shape,
          ),
        ),
      ),
    );
  }

  /// [base] with the theme's dark ink laid over it (its light ink over a dark face), as an
  /// opaque color: navy in Soft, gray in Day and Night.
  static Color _shaded(Color base, double amount, DenColors c) {
    if (amount == 0) return base;
    final (dark, light) = c.isDark ? (c.onPrimary, c.ink) : (c.ink, c.onPrimary);
    final toward = base.computeLuminance() > 0.5 ? dark : light;
    return Color.alphaBlend(toward.withValues(alpha: amount), base);
  }
}

/// A chunky shape that isn't pressed: the star card. Its face stands [depth] above a solid lip.
class ChunkySlab extends StatelessWidget {
  const ChunkySlab({
    super.key,
    required this.child,
    required this.face,
    required this.lip,
    this.depth = Lip.card,
    this.radius = Radii.kidCard,
  });

  final Widget child;
  final Color face;
  final Color lip;
  final double depth;
  final double radius;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _LipPainter(lip, radius, depth),
        child: Padding(
          padding: EdgeInsets.only(bottom: depth),
          child: DecoratedBox(
            decoration: BoxDecoration(color: face, borderRadius: BorderRadius.circular(radius)),
            child: child,
          ),
        ),
      );
}

/// The lip: the face's own shape, [depth] lower, in a solid color. No blur.
class _LipPainter extends CustomPainter {
  _LipPainter(this.color, this.radius, this.depth);

  final Color color;
  final double radius;
  final double depth;

  @override
  void paint(Canvas canvas, Size size) {
    if (depth <= 0 || size.height <= depth) return;
    final rect = Rect.fromLTWH(0, depth, size.width, size.height - depth);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_LipPainter old) => old.color != color || old.radius != radius || old.depth != depth;
}

/// The keyboard focus ring: 2 px of ink, 3 px outside the face.
class _Ring extends CustomPainter {
  _Ring(this.radius, this.color);

  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color;
    canvas.drawRRect(RRect.fromRectAndRadius((Offset.zero & size).inflate(3), Radius.circular(radius + 3)), paint);
  }

  @override
  bool shouldRepaint(_Ring old) => old.radius != radius || old.color != color;
}
