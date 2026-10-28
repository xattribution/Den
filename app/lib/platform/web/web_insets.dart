import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'web_app.dart';

/// Adds the screen's safe areas (the home indicator, the notch in landscape) to the padding
/// every SafeArea below reads. Den draws to the screen's edges as a Home Screen app
/// (`viewport-fit=cover`), and Flutter on the web reports no safe areas of its own, so without
/// this the tab bar would sit under the home indicator.
class WebSafeArea extends StatelessWidget {
  const WebSafeArea({super.key, required this.child, this.insets});

  final Widget? child;

  /// Top, right, bottom, left, for tests; by default read from the page.
  final List<double>? insets;

  @override
  Widget build(BuildContext context) {
    final child = this.child ?? const SizedBox.shrink();
    if (!kIsWeb && insets == null) return child;
    final media = MediaQuery.of(context);
    final i = insets ?? WebApp.insets();
    if (i.length != 4 || i.every((v) => v <= 0)) return child;
    final safe = EdgeInsets.fromLTRB(i[3], i[0], i[1], i[2]);
    final view = media.viewPadding + safe;
    // The keyboard covers the home indicator; its inset already lifts what it covers.
    final padding = EdgeInsets.fromLTRB(
      view.left,
      view.top,
      view.right,
      math.max(0.0, view.bottom - media.viewInsets.bottom),
    );
    return MediaQuery(data: media.copyWith(viewPadding: view, padding: padding), child: child);
  }
}
