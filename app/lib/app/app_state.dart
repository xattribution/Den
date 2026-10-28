import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/calendars/phone_calendars.dart';
import '../platform/sync/den_network.dart';
import '../platform/notifications/reminder_scheduler.dart';
import 'format.dart';
import 'family_reads.dart';

enum ThemeChoice { auto, day, night }

/// The app's live state: the device's [Den] engine plus UI preferences. Rebuilds listeners on
/// every change the engine applies, whether made here or synced from another device.
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

  /// Swaps the engine, for example when entering or leaving the demo family.
  void replaceDen(Den den) {
    _sub?.cancel();
    _den = den;
    _formats = null;
    _listen();
    notifyListeners();
  }

  bool _wall;

  /// Running as a shared wall display: larger type, the week grid first, "who's doing this?".
  bool get wall => _wall;
  set wall(bool value) {
    if (value == _wall) return;
    _wall = value;
    notifyListeners();
    _save((p) => p.setBool(_wallKey, value));
  }

  ThemeChoice _theme;
  ThemeChoice get theme => _theme;
  set theme(ThemeChoice value) {
    _theme = value;
    notifyListeners();
    _save((p) => p.setString(_themeKey, value.name));
  }

  StreamSubscription<Set<String>>? _sub;
  Formats? _formats;

  void _listen() {
    _sub = _den.onChange.listen((types) {
      if (types.contains(RecordType.family)) _formats = null;
      notifyListeners();
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

/// Makes [AppState] available below it and rebuilds dependents when it changes.
class DenScope extends InheritedNotifier<AppState> {
  const DenScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DenScope>()!.notifier!;

  static AppState read(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<DenScope>()!.widget as DenScope).notifier!;
}

extension DenContext on BuildContext {
  AppState get app => DenScope.of(this);
  Den get den => DenScope.of(this).den;
}
