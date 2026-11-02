import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// Den's motion (DESIGN.md, "Motion"): real springs for anything that moves, interruptible and
/// carrying the finger's velocity, and a 100 ms fade instead of movement under Reduce Motion.
/// Nothing else in the app invents a curve or a duration for movement.
abstract final class DenMotion {
  /// A spring described the way iOS does: its damping ratio and its response (the period it
  /// would swing at if undamped). Mass 1, stiffness (2π / response)².
  static SpringDescription spring({required double dampingRatio, required double response}) {
    final stiffness = math.pow(2 * math.pi / response, 2).toDouble();
    return SpringDescription.withDampingRatio(mass: 1, stiffness: stiffness, ratio: dampingRatio);
  }

  /// Menus, press feedback, reordering, inline changes: ratio 0.86, response 0.32 s. Overshoots
  /// under 1 %, which reads as none.
  static final SpringDescription ui = spring(dampingRatio: 0.86, response: 0.32);

  /// Sheets: critically damped, response 0.38 s.
  static final SpringDescription sheet = spring(dampingRatio: 1, response: 0.38);

  /// A check filling: ratio 0.7, response 0.24 s. One small settle, the only bounce allowed.
  static final SpringDescription check = spring(dampingRatio: 0.7, response: 0.24);

  /// What a spring becomes under Reduce Motion: an opacity fade this long, with nothing moving.
  static const Duration fade = Duration(milliseconds: 100);

  /// Press feedback: the scale on pointer down and how much the fill darkens (or lightens on a
  /// dark fill). Hover shades a little less.
  static const double pressScale = 0.97;
  static const double pressShade = 0.06;
  static const double hoverShade = 0.04;

  /// A sheet dismisses when flung down faster than this (logical pixels per second) or dragged
  /// past this fraction of its height.
  static const double dismissVelocity = 700;
  static const double dismissFraction = 0.35;

  /// Whether the platform asks for reduced motion.
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// How long [spring] takes to come within [tolerance] of its target from a standstill, for the
  /// few places Flutter wants a duration.
  static Duration settle(SpringDescription spring, {double tolerance = 0.001}) {
    final simulation = SpringSimulation(spring, 0, 1, 0);
    const step = 1 / 240;
    var t = 0.0;
    while (t < 3 && ((simulation.x(t) - 1).abs() > tolerance || simulation.dx(t).abs() > tolerance * 10)) {
      t += step;
    }
    return Duration(microseconds: (t * Duration.microsecondsPerSecond).round());
  }

  static final Duration uiSettle = settle(ui);
  static final Duration sheetSettle = settle(sheet);

  /// [ui] as a curve over [uiSettle], for implicit animations such as AnimatedSize.
  static final Curve uiCurve = SpringCurve(ui);

  /// [check] as a duration and a curve: a kid tile filling and its check drawing.
  static final Duration checkSettle = settle(check);
  static final Curve checkCurve = SpringCurve(check);
}

/// A spring from 0 to 1 as a curve, over the time it takes to settle. Use it only where Flutter
/// insists on a duration and a curve; anything a finger can grab uses [DenSpring.springTo].
class SpringCurve extends Curve {
  SpringCurve(this.spring)
      : _simulation = SpringSimulation(spring, 0, 1, 0),
        _seconds = DenMotion.settle(spring).inMicroseconds / Duration.microsecondsPerSecond;

  final SpringDescription spring;
  final SpringSimulation _simulation;
  final double _seconds;

  @override
  double transformInternal(double t) => _simulation.x(t * _seconds);
}

extension DenSpring on AnimationController {
  /// Springs from wherever the value is now to [target], carrying the current velocity (or
  /// [velocity], in units per second, such as a released drag's) so an animation grabbed
  /// mid-flight continues without a jump. It ends exactly on [target].
  TickerFuture springTo(double target, {SpringDescription? spring, double? velocity}) =>
      animateWith(LandingSpring(spring ?? DenMotion.ui, value, target, velocity ?? this.velocity));
}

/// A spring that lands exactly on its end: once it is within tolerance it reports the end
/// itself, so nothing rests a fraction of a pixel short.
class LandingSpring extends Simulation {
  LandingSpring(SpringDescription spring, double start, this.end, double velocity)
      : _spring = SpringSimulation(spring, start, end, velocity);

  final double end;
  final SpringSimulation _spring;

  @override
  double x(double time) => _spring.isDone(time) ? end : _spring.x(time);

  @override
  double dx(double time) => _spring.isDone(time) ? 0 : _spring.dx(time);

  @override
  bool isDone(double time) => _spring.isDone(time);
}

/// Press feedback for anything tappable: a button, a row, a chip. On pointer down (in the same
/// frame) it scales to 0.97 and shades its fill 6 %, and springs back on release; a drag that
/// leaves the slop releases it. Keyboard focus draws a 2 px ink ring with a gap; a pointer's
/// hover shades it a little. Under Reduce Motion only the shade changes.
class DenPressable extends StatefulWidget {
  const DenPressable({
    super.key,
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.color,
    this.shape = const StadiumBorder(),
    this.scale = true,
    this.haptic = false,
    this.semanticLabel,
    this.selected,
    this.toggled,
    this.focusNode,
    this.autofocus = false,
  });

  final VoidCallback? onTap;

  /// Only ever a second way to the same actions: never the only way to anything.
  final VoidCallback? onLongPress;
  final Widget child;

  /// The resting fill. Null leaves it clear; pressing then lays ink over it at 6 %.
  final Color? color;
  final ShapeBorder shape;

  /// False for wide rows, where a scale would read as the whole list moving.
  final bool scale;

  /// A light selection click on tap: for check-off, approve and drop.
  final bool haptic;
  final String? semanticLabel;
  final bool? selected;
  final bool? toggled;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<DenPressable> createState() => _DenPressableState();
}

class _DenPressableState extends State<DenPressable> with SingleTickerProviderStateMixin {
  /// The platform's touch slop: past this a press becomes a scroll.
  static const double _slop = 18;

  /// Made the first time something presses with [DenPressable.scale] on; rows that never scale
  /// never make one.
  AnimationController? _scaleController;
  AnimationController get _scale => _scaleController ??= AnimationController.unbounded(vsync: this, value: 1);
  int? _pointer;
  Offset? _downAt;
  bool _pressed = false;
  bool _hovered = false;
  bool _focused = false;
  bool _reduced = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  @override
  void dispose() {
    _scaleController?.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
    if (!widget.scale || _reduced) {
      _scaleController?.value = 1;
    } else {
      _scale.springTo(pressed ? DenMotion.pressScale : 1);
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
    if (widget.haptic) HapticFeedback.selectionClick();
    widget.onTap?.call();
  }

  static Color? _shaded(Color? base, double amount, DenColors c) {
    if (amount == 0) return base;
    if (base == null || base.a == 0) return c.ink.withValues(alpha: amount);
    final toward = base.computeLuminance() > 0.5 ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    return Color.alphaBlend(toward.withValues(alpha: amount), base);
  }

  @override
  Widget build(BuildContext context) {
    _reduced = DenMotion.reduced(context);
    final c = context.colors;
    final shade = !_enabled
        ? 0.0
        : _pressed
            ? DenMotion.pressShade
            : _hovered
                ? DenMotion.hoverShade
                : 0.0;
    Widget result = DecoratedBox(
      decoration: ShapeDecoration(shape: widget.shape, color: _shaded(widget.color, shade, c)),
      child: widget.child,
    );
    if (_focused) result = CustomPaint(foregroundPainter: _FocusRing(widget.shape, c.ink), child: result);
    if (widget.scale) result = ScaleTransition(scale: _scale, child: result);

    return Semantics(
      container: true,
      button: true,
      enabled: _enabled,
      selected: widget.selected,
      toggled: widget.toggled,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: _enabled,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
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
            child: result,
          ),
        ),
      ),
    );
  }
}

/// The keyboard focus ring: 2 px of ink, 3 px outside the shape.
class _FocusRing extends CustomPainter {
  _FocusRing(this.shape, this.color);

  final ShapeBorder shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color;
    canvas.drawPath(shape.getOuterPath((Offset.zero & size).inflate(3)), paint);
  }

  @override
  bool shouldRepaint(_FocusRing old) => old.shape != shape || old.color != color;
}

/// Shows or hides [child] in place: it grows and fades in on the UI spring and shrinks and fades
/// out the same way, so rows below move instead of jumping. Under Reduce Motion it takes its
/// full size at once and only fades, for 100 ms.
class DenReveal extends StatefulWidget {
  const DenReveal({
    super.key,
    required this.visible,
    required this.child,
    this.axis = Axis.vertical,
    this.axisAlignment = -1,
  });

  final bool visible;
  final Widget child;
  final Axis axis;
  final double axisAlignment;

  @override
  State<DenReveal> createState() => _DenRevealState();
}

class _DenRevealState extends State<DenReveal> with TickerProviderStateMixin {
  late final AnimationController _size = AnimationController.unbounded(vsync: this, value: widget.visible ? 1 : 0);
  late final AnimationController _fade =
      AnimationController(vsync: this, duration: DenMotion.fade, value: widget.visible ? 1 : 0);
  late final Animation<double> _sizeFactor = _size.drive(const _Unit());
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = DenMotion.reduced(context);
  }

  @override
  void didUpdateWidget(DenReveal old) {
    super.didUpdateWidget(old);
    if (old.visible == widget.visible) return;
    if (_reduced) {
      if (widget.visible) {
        _size.value = 1;
        _fade.forward();
      } else {
        _fade.reverse().whenCompleteOrCancel(() {
          if (mounted && !widget.visible) _size.value = 0;
        });
      }
    } else {
      _fade.value = 1;
      _size.springTo(widget.visible ? 1 : 0);
    }
  }

  @override
  void dispose() {
    _size.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hidden = !widget.visible;
    return ExcludeFocus(
      excluding: hidden,
      child: ExcludeSemantics(
        excluding: hidden,
        child: IgnorePointer(
          ignoring: hidden,
          child: SizeTransition(
            sizeFactor: _sizeFactor,
            axis: widget.axis,
            axisAlignment: widget.axisAlignment,
            child: FadeTransition(opacity: _reduced ? _fade : _sizeFactor, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// A spring can pass its target a little; sizes and opacities can't.
class _Unit extends Animatable<double> {
  const _Unit();

  @override
  double transform(double t) => t.clamp(0.0, 1.0);
}

/// A number that moves to [value] on a spring whenever it changes, for the small state changes a
/// tap causes: a check filling, a switch's knob, a caret turning, a goal bar growing. It starts
/// from where it is and as fast as it is going, so a second tap mid-flight turns it around
/// without a jump. [builder] draws it each frame; the value can pass its target a little on a
/// bouncy spring ([DenMotion.check]), so clamp what can't. Under Reduce Motion nothing moves:
/// the old look crossfades to the new one in 100 ms.
class SpringValue extends StatefulWidget {
  const SpringValue({super.key, required this.value, required this.builder, this.spring, this.child});

  final double value;

  /// [DenMotion.ui] unless given.
  final SpringDescription? spring;
  final ValueWidgetBuilder<double> builder;

  /// Handed to [builder] unchanged, for the part that doesn't move.
  final Widget? child;

  @override
  State<SpringValue> createState() => _SpringValueState();
}

class _SpringValueState extends State<SpringValue> with TickerProviderStateMixin {
  late final AnimationController _value = AnimationController.unbounded(vsync: this, value: widget.value);
  AnimationController? _fadeController;

  /// The value fading out under Reduce Motion, until the fade ends.
  double? _from;

  AnimationController get _fade => _fadeController ??= AnimationController(vsync: this, duration: DenMotion.fade)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) setState(() => _from = null);
    });

  @override
  void didUpdateWidget(SpringValue old) {
    super.didUpdateWidget(old);
    if (old.value == widget.value) return;
    if (DenMotion.reduced(context)) {
      _from = _value.value;
      _value.value = widget.value;
      _fade.forward(from: 0);
    } else {
      _from = null;
      _fadeController?.value = 1;
      _value.springTo(widget.value, spring: widget.spring ?? DenMotion.ui);
    }
  }

  @override
  void dispose() {
    _value.dispose();
    _fadeController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final from = _from;
    if (from != null) {
      return Stack(
        alignment: Alignment.center,
        children: [
          ExcludeSemantics(
            child: FadeTransition(opacity: ReverseAnimation(_fade), child: widget.builder(context, from, widget.child)),
          ),
          FadeTransition(opacity: _fade, child: widget.builder(context, widget.value, widget.child)),
        ],
      );
    }
    return AnimatedBuilder(
      animation: _value,
      builder: (context, child) => widget.builder(context, _value.value, child),
      child: widget.child,
    );
  }
}

/// Swaps one state of a piece for another in place ("Nobody is driving Leo" for "You're driving
/// Leo, Undo"): the old one fades out as the new one fades in, and the height follows on the UI
/// spring. Give each state's widget its own key. Under Reduce Motion it is a 100 ms crossfade
/// and the height changes at once.
class DenCrossfade extends StatelessWidget {
  const DenCrossfade({super.key, required this.child, this.alignment = AlignmentDirectional.topStart});

  final Widget child;
  final AlignmentGeometry alignment;

  /// The crossfade itself is opacity, not movement.
  static const Duration duration = Duration(milliseconds: 160);

  @override
  Widget build(BuildContext context) {
    final reduced = DenMotion.reduced(context);
    return AnimatedSize(
      duration: reduced ? Duration.zero : DenMotion.uiSettle,
      curve: reduced ? Curves.linear : DenMotion.uiCurve,
      alignment: alignment,
      child: AnimatedSwitcher(
        duration: reduced ? DenMotion.fade : duration,
        layoutBuilder: (current, previous) => Stack(alignment: alignment, children: [...previous, ?current]),
        child: child,
      ),
    );
  }
}
