import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/calendars/phone_calendars.dart';
import '../platform/sync/den_network.dart';
import '../platform/notifications/reminder_scheduler.dart';
import 'actions.dart';
import 'den_scope.dart';
import 'family_reads.dart';
import 'format.dart';

export 'actions.dart';
export 'den_scope.dart';

enum ThemeChoice { auto, day, night }

/// What a change can touch besides record types ([RecordType]).
abstract final class Changes {
  /// The theme or the wall setting of this device.
  static const prefs = 'prefs';

  /// Everything: the engine itself was swapped (the demo family).
  static const all = 'all';

  /// Who's who and what they may do, which nearly every screen reads: the family's settings,
  /// its people, its devices, and who is acting on this device.
  static const people = {RecordType.family, RecordType.member, RecordType.device, Den.actingChanged};
}

/// The app's live state: the device's [Den] engine plus UI preferences. Tells listeners what
/// each change touched ([lastChange]), whether made here or synced from another device, so
/// [DenScope] rebuilds only the widgets that read it.
class AppState extends ChangeNotifier with FamilyReads {
  AppState(
    Den den, {
    bool wall = false,
    ThemeChoice theme = ThemeChoice.auto,
    this.network,
    this.reminders,
    this.phoneCalendars,
  })
      : _den = den,
        _wall = wall,
        _theme = theme {
    _listen();
  }

  /// Restores the saved theme and wall preferences for this device.
  static Future<AppState> load(
    Den den, {
    DenNetwork? network,
    ReminderScheduler? reminders,
    PhoneCalendars? phoneCalendars,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    return AppState(
      den,
      wall: prefs.getBool(_wallKey) ?? false,
      theme: ThemeChoice.values.asNameMap()[prefs.getString(_themeKey)] ?? ThemeChoice.auto,
      network: network,
      reminders: reminders,
      phoneCalendars: phoneCalendars,
    );
  }

  /// This device's sync with the hub and other devices; null for the demo family and in tests.
  final DenNetwork? network;

  /// This device's reminder notifications; null in tests. It follows the device's own engine,
  /// never the demo family's.
  final ReminderScheduler? reminders;

  /// Calendars brought in from this phone; null where there are none to bring in, and in tests.
  final PhoneCalendars? phoneCalendars;

  static const _wallKey = 'den.wall';
  static const _themeKey = 'den.theme';

  Den _den;
  @override
  Den get den => _den;

  /// Every change the app makes goes through these.
  late final AppActions actions = AppActions(() => _den);

  /// Swaps the engine, for example when entering or leaving the demo family.
  void replaceDen(Den den) {
    _sub?.cancel();
    _den = den;
    _formats = null;
    _views.clear();
    _listen();
    _changed(const {Changes.all});
  }

  /// What the latest change touched: record types, [Den.actingChanged], [Changes.prefs], or
  /// [Changes.all].
  Set<String> get lastChange => _lastChange;
  Set<String> _lastChange = const {};
  final Map<String, int> _versions = {};

  void _changed(Set<String> touched) {
    _lastChange = touched;
    for (final t in touched) {
      _versions[t] = (_versions[t] ?? 0) + 1;
    }
    notifyListeners();
  }

  /// A number that changes exactly when one of [types] (or everything) has changed.
  int versionOf(Iterable<String> types) {
    var n = _versions[Changes.all] ?? 0;
    for (final t in types) {
      n += _versions[t] ?? 0;
    }
    return n;
  }

  final Map<Object, (int, Object?)> _views = {};

  /// [view]'s value: kept from the last time until one of the record types it reads, who's
  /// who, or the day changes.
  T view<T>(DenView<T> view) {
    final key = (view.key, today);
    final version = versionOf({...Changes.people, ...view.reads});
    final kept = _views[key];
    if (kept != null && kept.$1 == version) return kept.$2 as T;
    final value = view.compute(this);
    _views[key] = (version, value);
    return value;
  }

  /// A listenable that fires only for changes to [types] (or to everything), for the router and
  /// the theme. Its owner disposes it.
  ChangeNotifier watching(Set<String> types) => _Watching(this, types);

  bool _wall;

  /// Running as a shared wall display: larger type, the week grid first, "who's doing this?".
  bool get wall => _wall;
  set wall(bool value) {
    if (value == _wall) return;
    _wall = value;
    _changed(const {Changes.prefs});
    _save((p) => p.setBool(_wallKey, value));
  }

  ThemeChoice _theme;
  ThemeChoice get theme => _theme;
  set theme(ThemeChoice value) {
    _theme = value;
    _changed(const {Changes.prefs});
    _save((p) => p.setString(_themeKey, value.name));
  }

  StreamSubscription<Set<String>>? _sub;
  Formats? _formats;

  void _listen() {
    _sub = _den.onChange.listen((types) {
      if (types.contains(RecordType.family)) _formats = null;
      _changed(types);
    });
  }

  static void _save(Future<bool> Function(SharedPreferences) write) {
    unawaited(SharedPreferences.getInstance().then(write).catchError((Object _) => false));
  }

  @override
  Formats get formats => _formats ??= Formats(den.family?.timezone ?? 'UTC');

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

class _Watching extends ChangeNotifier {
  _Watching(this._state, this._types) {
    _state.addListener(_check);
  }

  final AppState _state;
  final Set<String> _types;

  void _check() {
    final touched = _state.lastChange;
    if (touched.contains(Changes.all) || touched.any(_types.contains)) notifyListeners();
  }

  @override
  void dispose() {
    _state.removeListener(_check);
    super.dispose();
  }
}
