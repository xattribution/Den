import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'web_app.dart';
import '../capabilities.dart';

/// The keyboard inset the app should lay out with, given Flutter's own ([flutter]) and the
/// page's answer ([page], from web/den_web.js; null where it isn't asked).
///
/// Flutter on iOS reads the keyboard from the visual viewport only on a resize event and only
/// while it thinks a field is being edited. A keyboard closed with its own button, rather than
/// Return, can leave that reading stale, or iOS 26 can leave the visual viewport a little short
/// with no keyboard at all; either way the app stays lifted over a keyboard that's gone. The page
/// knows whether a field has the browser's focus and how much the keyboard covers, so where it
/// answers, its answer is the keyboard.
EdgeInsets webViewInsets(EdgeInsets flutter, WebViewport? page) {
  if (page == null) return flutter;
  return EdgeInsets.fromLTRB(flutter.left, flutter.top, flutter.right, page.keyboard);
}

/// The page's answer on an iPhone or iPad, kept current by den_web.js; it stays null elsewhere
/// (other browsers measure the keyboard the way Flutter expects). Made the first time the app
/// asks.
final ValueNotifier<WebViewport?> _iosPage = () {
  final page = ValueNotifier<WebViewport?>(null);
  if (Capabilities.web && WebApp.info.ios) WebApp.onViewport((v) => page.value = v);
  return page;
}();

/// Adds the screen's safe areas (the home indicator, the notch in landscape) to the padding
/// every SafeArea below reads, and on an iPhone or iPad takes the keyboard's height from the page
/// ([webViewInsets]). Den draws to the screen's edges as a Home Screen app
/// (`viewport-fit=cover`), and Flutter on the web reports no safe areas of its own, so without
/// this the tab bar would sit under the home indicator.
class WebSafeArea extends StatelessWidget {
  const WebSafeArea({super.key, required this.child, this.insets, this.viewport});

  final Widget? child;

  /// Top, right, bottom, left, for tests; by default read from the page.
  final List<double>? insets;

  /// The page's keyboard answer, for tests; by default den_web.js's on an iPhone or iPad.
  final ValueListenable<WebViewport?>? viewport;

  @override
  Widget build(BuildContext context) {
    final source = viewport ?? (Capabilities.web ? _iosPage : null);
    if (source == null) return _apply(context, null);
    return ValueListenableBuilder<WebViewport?>(
      valueListenable: source,
      builder: (context, page, _) => _apply(context, page),
    );
  }

  Widget _apply(BuildContext context, WebViewport? page) {
    final child = this.child ?? const SizedBox.shrink();
    if (!Capabilities.web && insets == null && page == null) return child;
    final media = MediaQuery.of(context);
    final i = insets ?? (Capabilities.web ? WebApp.insets() : const <double>[0, 0, 0, 0]);
    final safe = i.length == 4 && i.any((v) => v > 0)
        ? EdgeInsets.fromLTRB(math.max(0, i[3]), math.max(0, i[0]), math.max(0, i[1]), math.max(0, i[2]))
        : EdgeInsets.zero;
    final keyboard = webViewInsets(media.viewInsets, page);
    if (safe == EdgeInsets.zero && keyboard == media.viewInsets) return child;
    final view = media.viewPadding + safe;
    // The keyboard covers the home indicator; its inset already lifts what it covers.
    final padding = EdgeInsets.fromLTRB(
      view.left,
      view.top,
      view.right,
      math.max(0.0, view.bottom - keyboard.bottom),
    );
    return MediaQuery(
      data: media.copyWith(viewPadding: view, padding: padding, viewInsets: keyboard),
      child: child,
    );
  }
}
