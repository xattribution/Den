import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'layout.dart';
import 'motion.dart';
import 'tokens.dart';

/// Opens [builder] in a Den sheet and completes with what the sheet pops. A sheet opened from
/// a part of the app drawn in another theme than the app's (the calendar kept light at night)
/// takes that theme: its surface, handle, scrim and everything in it.
Future<T?> showDenSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
  String closeLabel = 'Close',
  RouteSettings? settings,
}) {
  final navigator = Navigator.of(context);
  final theme = Theme.of(context);
  return navigator.push<T>(
    DenSheetRoute<T>(
      builder: builder,
      dismissible: dismissible,
      closeLabel: closeLabel,
      settings: settings,
      theme: identical(theme, Theme.of(navigator.context)) ? null : theme,
    ),
  );
}

/// A sheet: from the bottom edge on phones, a centered form sheet at most 560 wide on iPad, with
/// 28 corners on the page's background and the page behind dimmed. It moves on the critically
/// damped sheet spring, follows a drag 1:1, and on release carries the finger's velocity into
/// the spring: flung down past 700 pt/s or dragged past 35 % of its height it closes, otherwise
/// it settles back. Every movement can be grabbed mid-flight. Under Reduce Motion it fades in
/// and out in 100 ms and never slides.
class DenSheetRoute<T> extends PopupRoute<T> {
  DenSheetRoute({required this.builder, this.dismissible = true, this.closeLabel = 'Close', this.theme, super.settings});

  final WidgetBuilder builder;

  /// The theme of the whole sheet (surface, handle, scrim and content) when it isn't the app's:
  /// a sheet opened from the calendar kept light in a dark app. Null follows the app.
  final ThemeData? theme;

  /// Whether a drag, a tap outside or the back gesture closes it.
  final bool dismissible;

  /// What screen readers call the area outside the sheet and its handle.
  final String closeLabel;

  bool _reduced = false;

  /// Whether Reduce Motion was on when the sheet opened.
  bool get reducedMotion => _reduced;

  @override
  void install() {
    _reduced = MediaQuery.maybeDisableAnimationsOf(navigator!.context) ?? false;
    super.install();
  }

  /// The sheet paints its own scrim, on its own spring.
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => dismissible;

  @override
  String? get barrierLabel => closeLabel;

  // The route stays until the spring has settled; the sheet itself does the moving.
  @override
  Duration get transitionDuration => _reduced ? DenMotion.fade : DenMotion.sheetSettle;

  @override
  Duration get reverseTransitionDuration => transitionDuration;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final page = _DenSheetPage<T>(route: this);
    return theme == null ? page : Theme(data: theme!, child: page);
  }
}

class _DenSheetPage<T> extends StatefulWidget {
  const _DenSheetPage({super.key, required this.route});

  final DenSheetRoute<T> route;

  @override
  State<_DenSheetPage<T>> createState() => _DenSheetPageState<T>();
}

class _DenSheetPageState<T> extends State<_DenSheetPage<T>> with TickerProviderStateMixin {
  /// How far the sheet is from open: 0 open, 1 out of sight. Unbounded so a spring can carry
  /// any velocity; what's drawn is clamped.
  late final AnimationController _position =
      AnimationController.unbounded(vsync: this, value: widget.route.reducedMotion ? 0 : 1);

  /// Only moves under Reduce Motion: the sheet's and the scrim's opacity.
  late final AnimationController _fade =
      AnimationController(vsync: this, duration: DenMotion.fade, value: widget.route.reducedMotion ? 0 : 1);

  final GlobalKey _sheetKey = GlobalKey();
  Animation<double>? _routeAnimation;
  bool _closing = false;
  bool _dragging = false;
  bool _centered = false;

  /// A release's velocity in sheet units per second, handed to the closing spring.
  double? _releaseVelocity;

  bool get _reduced => widget.route.reducedMotion;

  @override
  void initState() {
    super.initState();
    _routeAnimation = widget.route.animation?..addStatusListener(_routeStatus);
    if (_reduced) {
      _fade.forward();
    } else {
      _position.springTo(0, spring: DenMotion.sheet);
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_routeStatus);
    _position.dispose();
    _fade.dispose();
    super.dispose();
  }

  /// The route is closing (a pop from the sheet, a tap outside, the back gesture): spring out.
  void _routeStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse && !_closing) _close();
  }

  void _close() {
    _closing = true;
    _dragging = false;
    if (_reduced) {
      _fade.reverse();
    } else {
      _position.springTo(1, spring: DenMotion.sheet, velocity: _releaseVelocity ?? _position.velocity);
    }
  }

  double get _sheetHeight {
    final box = _sheetKey.currentContext?.findRenderObject() as RenderBox?;
    return box != null && box.hasSize ? box.size.height : 1;
  }

  /// How far the sheet moves between open and out of sight.
  double get _travel => _RenderSheetSlide.travelFor(
        sheetHeight: _sheetHeight,
        viewportHeight: MediaQuery.sizeOf(context).height,
        centered: _centered,
      );

  void _dragStart(DragStartDetails details) {
    if (_closing) return;
    _dragging = true;
    _position.stop();
  }

  void _dragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    _position.value = (_position.value + details.primaryDelta! / _travel).clamp(0.0, 1.0);
  }

  void _dragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final travel = _travel;
    final velocity = details.primaryVelocity ?? 0;
    final dragged = _position.value * travel;
    final close = widget.route.dismissible &&
        (velocity > DenMotion.dismissVelocity ||
            (dragged > _sheetHeight * DenMotion.dismissFraction && velocity > -DenMotion.dismissVelocity));
    if (!close) {
      _position.springTo(0, spring: DenMotion.sheet, velocity: velocity / travel);
      return;
    }
    _releaseVelocity = velocity / travel;
    Navigator.of(context).maybePop().then((popped) {
      if (!popped && mounted && !_closing) {
        _releaseVelocity = null;
        _position.springTo(0, spring: DenMotion.sheet);
      }
    });
  }

  void _dragCancel() {
    if (!_dragging) return;
    _dragging = false;
    _position.springTo(0, spring: DenMotion.sheet);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final media = MediaQuery.of(context);
    _centered = DenLayout.forWidth(media.size.width).centersSheets;
    // Over the keyboard too, a sheet stops short of the status bar.
    final maxHeight = _centered
        ? media.size.height * 0.86
        : math.max(0.0, media.size.height - media.viewInsets.bottom - media.padding.top - Sp.s);
    final radius = _centered
        ? const BorderRadius.all(Radius.circular(Radii.sheet))
        : const BorderRadius.vertical(top: Radius.circular(Radii.sheet));

    final sheet = ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: maxHeight,
        maxWidth: _centered ? DenLayout.sheetMaxWidth : double.infinity,
      ),
      child: Material(
        color: c.bg,
        shape: RoundedRectangleBorder(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: MediaQuery(
          // The whole sheet is already lifted over the keyboard (the padding below), so what's
          // inside lays out as if there were none. A field's own "keyboard height" padding then
          // can't count it a second time and squeeze the sheet's words out of sight.
          data: media.removePadding(removeTop: true, removeBottom: true).removeViewInsets(removeBottom: true),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Handle(label: widget.route.closeLabel, dismissible: widget.route.dismissible),
              Flexible(
                child: Padding(
                  // Above the home indicator on phones (the keyboard's own inset is outside).
                  padding: EdgeInsets.only(
                    bottom: !_centered && media.padding.bottom > Sp.l ? media.padding.bottom : Sp.l,
                  ),
                  child: Builder(builder: widget.route.builder),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _Scrim(c.scrim, _reduced ? _fade : _position, reduced: _reduced)),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(
            top: _centered ? Sp.xl : 0,
            bottom: media.viewInsets.bottom + (_centered ? Sp.xl : 0),
          ),
          child: Align(
            alignment: _centered ? Alignment.center : Alignment.bottomCenter,
            child: _SheetSlide(
              progress: _position,
              centered: _centered,
              viewportHeight: media.size.height,
              child: FadeTransition(
                opacity: _fade,
                child: GestureDetector(
                  onVerticalDragStart: _dragStart,
                  onVerticalDragUpdate: _dragUpdate,
                  onVerticalDragEnd: _dragEnd,
                  onVerticalDragCancel: _dragCancel,
                  child: RepaintBoundary(key: _sheetKey, child: sheet),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The grab handle: 40 x 5 in the handle gray. Screen readers get it as the close button.
class _Handle extends StatelessWidget {
  const _Handle({required this.label, required this.dismissible});

  final String label;
  final bool dismissible;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: dismissible,
      label: dismissible ? label : null,
      onTap: dismissible ? () => Navigator.of(context).maybePop() : null,
      child: SizedBox(
        height: Sp.l + 5,
        child: Center(
          child: Container(
            width: 40,
            height: 5,
            decoration: BoxDecoration(color: c.handle, borderRadius: BorderRadius.circular(3)),
          ),
        ),
      ),
    );
  }
}

/// The dimmed page behind the sheet, painted at the sheet's progress without a layer.
class _Scrim extends CustomPainter {
  _Scrim(this.color, this.progress, {required this.reduced}) : super(repaint: progress);

  final Color color;

  /// The sheet's position (0 open), or under Reduce Motion its opacity.
  final Animation<double> progress;
  final bool reduced;

  @override
  void paint(Canvas canvas, Size size) {
    final shown = (reduced ? progress.value : 1 - progress.value).clamp(0.0, 1.0);
    if (shown == 0) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = color.withValues(alpha: color.a * shown));
  }

  @override
  bool shouldRepaint(_Scrim old) => old.color != color || old.progress != progress || old.reduced != reduced;
}

/// Draws its child moved down by progress times its travel, in paint only: no layout per frame.
class _SheetSlide extends SingleChildRenderObjectWidget {
  const _SheetSlide({required this.progress, required this.centered, required this.viewportHeight, super.child});

  final Animation<double> progress;
  final bool centered;
  final double viewportHeight;

  @override
  _RenderSheetSlide createRenderObject(BuildContext context) => _RenderSheetSlide(progress, centered, viewportHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderSheetSlide renderObject) {
    renderObject
      ..progress = progress
      ..centered = centered
      ..viewportHeight = viewportHeight;
  }
}

class _RenderSheetSlide extends RenderProxyBox {
  _RenderSheetSlide(this._progress, this._centered, this._viewportHeight);

  Animation<double> _progress;
  set progress(Animation<double> value) {
    if (identical(value, _progress)) return;
    if (attached) _progress.removeListener(markNeedsPaint);
    _progress = value;
    if (attached) _progress.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  bool _centered;
  set centered(bool value) {
    if (value == _centered) return;
    _centered = value;
    markNeedsPaint();
  }

  double _viewportHeight;
  set viewportHeight(double value) {
    if (value == _viewportHeight) return;
    _viewportHeight = value;
    markNeedsPaint();
  }

  /// From open to out of sight: the sheet's own height from the bottom edge, or from the middle
  /// of the screen to below it.
  static double travelFor({required double sheetHeight, required double viewportHeight, required bool centered}) =>
      centered ? (viewportHeight + sheetHeight) / 2 : sheetHeight;

  double get _dy {
    if (!hasSize) return 0;
    final p = _progress.value.clamp(0.0, 1.0);
    return p * travelFor(sheetHeight: size.height, viewportHeight: _viewportHeight, centered: _centered);
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _progress.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child != null) context.paintChild(child, offset.translate(0, _dy));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: Offset(0, _dy),
      position: position,
      hitTest: (inner, transformed) => child.hitTest(inner, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    transform.multiply(Matrix4.translationValues(0, _dy, 0));
  }
}
