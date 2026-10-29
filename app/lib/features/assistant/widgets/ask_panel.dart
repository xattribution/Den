import 'package:flutter/material.dart';

import '../../../design/motion.dart';
import '../../../design/tokens.dart';

/// Ask as a panel at the right edge from 840 pt (an iPad, a laptop), with the page behind it in
/// view so an answer can be read beside the calendar it talks about. It slides in and out on the
/// sheet spring and follows a drag to the right 1:1, closing when flung or dragged past 35 % of
/// its width; a tap beside it, Escape or the back gesture closes it too. Under Reduce Motion it
/// fades in and out in 100 ms and never slides. Give it the route's page key.
class AskPanelPage<T> extends Page<T> {
  const AskPanelPage({super.key, required this.child, this.width = 420, this.closeLabel = 'Close Ask', super.name});

  final Widget child;
  final double width;
  final String closeLabel;

  @override
  Route<T> createRoute(BuildContext context) {
    late final _AskPanelRoute<T> route;
    route = _AskPanelRoute<T>(
      builder: (_) => (route.settings as AskPanelPage<T>).child,
      width: width,
      closeLabel: closeLabel,
      settings: this,
    );
    return route;
  }
}

class _AskPanelRoute<T> extends PopupRoute<T> {
  _AskPanelRoute({required this.builder, required this.width, required this.closeLabel, super.settings});

  final WidgetBuilder builder;
  final double width;
  final String closeLabel;
  bool _reduced = false;

  @override
  void install() {
    _reduced = MediaQuery.maybeDisableAnimationsOf(navigator!.context) ?? false;
    super.install();
  }

  /// The page behind stays as it is: no scrim.
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => closeLabel;

  @override
  Duration get transitionDuration => _reduced ? DenMotion.fade : DenMotion.sheetSettle;

  @override
  Duration get reverseTransitionDuration => transitionDuration;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      _Panel<T>(route: this);
}

class _Panel<T> extends StatefulWidget {
  const _Panel({super.key, required this.route});

  final _AskPanelRoute<T> route;

  @override
  State<_Panel<T>> createState() => _PanelState<T>();
}

class _PanelState<T> extends State<_Panel<T>> with TickerProviderStateMixin {
  /// 0 in place, 1 out of sight to the right; unbounded so a spring can carry any velocity.
  late final AnimationController _position = AnimationController.unbounded(vsync: this, value: _reduced ? 0 : 1);
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: DenMotion.fade,
    value: _reduced ? 0 : 1,
  );
  Animation<double>? _routeAnimation;
  bool _closing = false;
  bool _dragging = false;
  double? _releaseVelocity;

  bool get _reduced => widget.route._reduced;

  double get _width {
    final available = MediaQuery.sizeOf(context).width;
    return available < widget.route.width ? available : widget.route.width;
  }

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

  void _dragStart(DragStartDetails _) {
    if (_closing || _reduced) return;
    _dragging = true;
    _position.stop();
  }

  void _dragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    _position.value = (_position.value + details.primaryDelta! / _width).clamp(0.0, 1.0);
  }

  void _dragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final velocity = details.primaryVelocity ?? 0;
    final close =
        velocity > DenMotion.dismissVelocity ||
        (_position.value > DenMotion.dismissFraction && velocity > -DenMotion.dismissVelocity);
    if (!close) {
      _position.springTo(0, spring: DenMotion.sheet, velocity: velocity / _width);
      return;
    }
    _releaseVelocity = velocity / _width;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final night = Theme.of(context).brightness == Brightness.dark;
    final width = _width;
    final panel = Material(
      color: c.bg,
      child: SafeArea(left: false, child: Builder(builder: widget.route.builder)),
    );
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: width,
        height: double.infinity,
        child: AnimatedBuilder(
          animation: _position,
          builder: (context, child) =>
              Transform.translate(offset: Offset(width * _position.value.clamp(0.0, 1.0), 0), child: child),
          child: FadeTransition(
            opacity: _fade,
            child: GestureDetector(
              onHorizontalDragStart: _dragStart,
              onHorizontalDragUpdate: _dragUpdate,
              onHorizontalDragEnd: _dragEnd,
              onHorizontalDragCancel: () {
                if (_dragging) {
                  _dragging = false;
                  _position.springTo(0, spring: DenMotion.sheet);
                }
              },
              child: RepaintBoundary(
                child: DecoratedBox(
                  // An overlay: the one soft shadow by day; at night a line edge instead.
                  decoration: BoxDecoration(
                    color: c.bg,
                    border: night ? Border(left: BorderSide(color: c.line)) : null,
                    boxShadow: night
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.14),
                              blurRadius: 32,
                              offset: const Offset(-4, 0),
                            ),
                          ],
                  ),
                  child: panel,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
