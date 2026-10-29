import 'handoff_stub.dart' if (dart.library.js_interop) 'handoff_web.dart' as impl;

/// Carries an invite or setup link from Safari into the Home Screen app.
///
/// A Home Screen web app on iOS has storage of its own, apart from Safari's, and opens at the
/// manifest's `start_url`, so the link someone tapped in Safari (with the invite's words in its
/// fragment) doesn't reach it. What Safari does copy, once, when someone adds a site to the
/// Home Screen (iOS and iPadOS 17.2 and later), is the site's cookies. So the page Safari shows
/// keeps the link's route in a first-party cookie ([keep]), only for as long as the invite
/// works and at most a day, and the Home Screen app takes it on its first start ([take]) and
/// clears it. The words never go further than the hub that served the page, which already
/// sees whatever the page holds. Where the copy doesn't happen (an older iOS, or Den already on
/// the Home Screen), the page's Copy invite and the app's Paste an invite do the same by hand.
abstract final class Handoff {
  /// The cookie's name.
  static const String name = 'den_handoff';

  static bool _taken = false;

  /// Keeps [route] (`/join/maple-river-canoe-tiger`) for the Home Screen app, for [life].
  static void keep(String route, {Duration life = const Duration(days: 1)}) =>
      impl.write(name, Uri.encodeComponent(route), life.inSeconds);

  /// The route Safari kept, once per start of the Home Screen app ([standalone]): read and
  /// cleared. Null when there is none, off the web, in Safari itself (which keeps it for the
  /// Home Screen app), and every time after the first.
  static String? take({required bool standalone}) {
    if (_taken || !standalone) return null;
    _taken = true;
    final raw = impl.read(name);
    if (raw == null || raw.isEmpty) return null;
    impl.write(name, '', 0);
    try {
      final route = Uri.decodeComponent(raw);
      return route.startsWith('/') ? route : null;
    } on ArgumentError {
      return null;
    }
  }

  /// Lets [take] read again (tests).
  static void debugReset() => _taken = false;
}
