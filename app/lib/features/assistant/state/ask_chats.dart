import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';
import 'ask_session.dart';
import 'helper_link.dart';

/// The one conversation Ask shows on this device, kept in memory while the app runs: closing Ask
/// and opening it again, from Today, the sidebar, Add or ⌘K, brings it back, and what Add sends
/// goes on from it. Nothing is written to the device or to the family's log.
///
/// A conversation is let go, and Ask starts a new one, when someone else is using the device,
/// when the family changes or gets a hub, after "New chat" ([startOver]), and when it has sat
/// untouched for [idle] or since another day: "tomorrow" in it would mean the wrong day, and
/// every question would send the old ones along again.
class AskChats {
  AskChats._(this.app);

  static final Expando<AskChats> _kept = Expando('AskChats');

  /// The conversations for [app]'s device.
  static AskChats of(AppState app) => _kept[app] ??= AskChats._(app);

  /// How long a conversation nobody touched is kept.
  static const Duration idle = Duration(hours: 3);

  final AppState app;

  /// The clock for [idle]; tests move it.
  DateTime Function() clock = DateTime.now;

  AskSession? _current;
  Den? _den;
  String? _who;
  DateTime _lastUsed = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastDay = '';

  /// The conversation being kept, if any, as it is.
  AskSession? get current => _current;

  /// The conversation to show for whoever is using the device now, through [link]: the one being
  /// kept, or a new one.
  AskSession session(HelperLink? link) {
    final kept = _current;
    if (kept != null && _fits(kept, link)) return kept;
    _letGo();
    final made = AskSession(app: app, link: link)..addListener(_used);
    _current = made;
    _den = app.den;
    _who = app.den.actor?.id;
    _used();
    return made;
  }

  /// "New chat": forgets the conversation (a turn still running changes nothing more) and starts
  /// another.
  AskSession startOver(HelperLink? link) {
    _letGo();
    return session(link);
  }

  bool _fits(AskSession s, HelperLink? link) {
    // A family that got a hub (or lost it) starts over; the same hub keeps it.
    if (s.closed || (s.link == null) != (link == null) || !identical(_den, app.den) || _who != app.den.actor?.id) {
      return false;
    }
    // Open on the screen, or still answering: kept, however long it has been.
    if (s.shown || s.busy) return true;
    return clock().difference(_lastUsed) < idle && _lastDay == app.today;
  }

  void _used() {
    _lastUsed = clock();
    _lastDay = app.today;
  }

  void _letGo() {
    final s = _current;
    _current = null;
    if (s == null) return;
    // A turn still running changes nothing more; a screen still holding it only lets go of it
    // (removing a listener is allowed after dispose).
    s
      ..removeListener(_used)
      ..close()
      ..dispose();
  }
}
