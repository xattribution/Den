import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../tokens.dart';

/// Width at which detail opens as a side panel over the page instead of a full page.
const double panelBreakpoint = 840;

/// A route page that is a side panel on wide screens (the page behind stays in view) and a
/// full page on phones.
Page<void> calendarPanelPage(BuildContext context, GoRouterState state, Widget child, {double width = 440}) {
  final wide = MediaQuery.sizeOf(context).width >= panelBreakpoint;
  if (!wide) return MaterialPage<void>(key: state.pageKey, child: child);
  return CustomTransitionPage<void>(
    key: state.pageKey,
    opaque: false,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    barrierLabel: 'Close',
    transitionDuration: Motion.sheet,
    reverseTransitionDuration: Motion.sheet,
    child: SidePanel(width: width, child: child),
    transitionsBuilder: (context, animation, _, panel) {
      if (MediaQuery.of(context).disableAnimations) return panel;
      final slide = Tween(begin: const Offset(0.08, 0), end: Offset.zero)
          .chain(CurveTween(curve: Motion.curve))
          .animate(animation);
      return FadeTransition(opacity: animation, child: SlideTransition(position: slide, child: panel));
    },
  );
}

/// The panel's frame: flush to the right edge, full height, the one overlay shadow.
class SidePanel extends StatelessWidget {
  const SidePanel({super.key, required this.width, required this.child});
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final available = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: available < width ? available : width,
        height: double.infinity,
        child: Container(
          decoration: BoxDecoration(
            color: c.paper,
            boxShadow: [BoxShadow(color: c.ink.withValues(alpha: 0.18), blurRadius: 24, offset: const Offset(0, 8))],
          ),
          // Drawn over the page inside, which paints its own background.
          foregroundDecoration: BoxDecoration(border: Border(left: BorderSide(color: c.rule))),
          child: child,
        ),
      ),
    );
  }
}
