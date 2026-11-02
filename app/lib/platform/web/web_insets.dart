import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../design/layout.dart';
import 'web_app.dart';
import '../capabilities.dart';

/// The keyboard inset the app should lay out with, given Flutter's own ([flutter]) and the
/// page's answer ([page], from web/den_web.js; null where it isn't asked). Never negative.
///
/// Flutter on iOS reads the keyboard from the visual viewport only on a resize event and only
/// while it thinks a field is being edited. A keyboard closed with its own button, rather than
/// Return, can leave that reading stale, or iOS 26 can leave the visual viewport a little short
/// with no keyboard at all; either way the app stays lifted over a keyboard that's gone. The page
/// knows whether a field has the browser's focus and how much the keyboard covers, so where it
/// answers, its answer is the keyboard.
///
/// Flutter 3.38.5 on Android can report a negative inset after a keyboard closed with its arrow
/// (den_web.js explains); nothing lays out under a negative inset.
EdgeInsets webViewInsets(EdgeInsets flutter, WebViewport? page) {
  EdgeInsets clamped(EdgeInsets e) =>
      EdgeInsets.fromLTRB(math.max(0, e.left), math.max(0, e.top), math.max(0, e.right), math.max(0, e.bottom));
  if (page == null) return clamped(flutter);
  return clamped(EdgeInsets.fromLTRB(flutter.left, flutter.top, flutter.right, page.keyboard));
}

/// The window's size for choosing its layout ([DenWindow]): Flutter's width, and the page's
/// height where the page has answered for the same width. The page's height is the layout
/// viewport's, which no keyboard changes in Safari or in Chrome since 108; Flutter's can shrink
/// by the keyboard while one is up on Android.
Size webWindowSize(Size flutter, WebViewport? page) {
  if (page == null || page.height <= 0 || (page.width - flutter.width).abs() > 2) return flutter;
  return Size(flutter.width, page.height);
}

/// The page's answer on a phone or tablet (iOS and Android), kept current by den_web.js; it stays
/// null elsewhere. Made the first time the app asks.
final ValueNotifier<WebViewport?> _mobilePage = () {
  final page = ValueNotifier<WebViewport?>(null);
  final info = WebApp.info;
  if (Capabilities.web && (info.ios || info.mobile)) WebApp.onViewport((v) => page.value = v);
  return page;
}();

/// Safari on an iPhone or iPad, asked once.
final bool _iosWeb = Capabilities.web && WebApp.info.ios;

/// Adds the screen's safe areas (the home indicator, the notch in landscape, Android's gesture
/// bar in an edge-to-edge app) to the padding every SafeArea below reads, on an iPhone or iPad
/// takes the keyboard's height from the page ([webViewInsets]), and tells [DenLayout] the
/// window's size as the page has it ([DenWindow]). Den draws to the screen's edges as a Home
/// Screen app (`viewport-fit=cover`), and Flutter on the web reports no safe areas of its own, so
/// without this the tab bar would sit under the home indicator.
class WebSafeArea extends StatelessWidget {
  const WebSafeArea({super.key, required this.child, this.insets, this.viewport, this.keyboardFromPage});

  final Widget? child;

  /// Top, right, bottom, left, for tests; by default read from the page.
  final List<double>? insets;

  /// The page's answer, for tests; by default den_web.js's on a phone or tablet.
  final ValueListenable<WebViewport?>? viewport;

  /// Whether the keyboard's height comes from the page rather than Flutter, for tests; by default
  /// on an iPhone or iPad. Android's Flutter measures the keyboard the way it expects.
  final bool? keyboardFromPage;

  @override
  Widget build(BuildContext context) {
    final source = viewport ?? (Capabilities.web ? _mobilePage : null);
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
    final fromPage = keyboardFromPage ?? _iosWeb;
    final keyboard = webViewInsets(media.viewInsets, fromPage ? page : null);
    final window = DenWindow(size: webWindowSize(media.size, page), child: child);
    // Always the same widgets above the app, so nothing below is built afresh when the keyboard
    // or the safe areas change.
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
      child: window,
    );
  }
}
