import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../calendars/phone_calendars.dart';
import '../net/den_network.dart';
import '../reminders/reminder_scheduler.dart';
import 'format.dart';

enum ThemeChoice { auto, day, night }

/// The app's live state: the device's [Den] engine plus UI preferences. Rebuilds listeners on
/// every change the engine applies, whether made here or synced from another device.
class AppState extends ChangeNotifier {
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

  Formats get formats => _formats ??= Formats(den.family?.timezone ?? 'UTC');

  String get today => den.todayDate();

  Member? get me => den.actor ?? den.owner;

  Member? memberById(String? id) => id == null ? null : den.member(id);

  List<Marker> markersFor(List<String> memberIds) {
    if (memberIds.isEmpty) return den.members.map((m) => m.marker).toList();
    return memberIds.map(den.member).whereType<Member>().map((m) => m.marker).toList();
  }

  /// Whether whoever is acting on this device may do [action]; used to hide what they can't.
  bool allows(DenAction action) {
    final actor = den.actor;
    if (actor != null) return can(actor, action);
    final device = den.thisDevice;
    return (device?.isShared ?? false) && can(null, action, openCheckoff: device?.openCheckoff ?? false);
  }

  /// Whether whoever is acting may add, change or remove list items. The engine allows that to
  /// whoever may edit lists, whoever added the item; checking an item off is
  /// [DenAction.checkItems]. Every add-item and edit-item control asks this.
  bool get canChangeItems => allows(DenAction.editLists);

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
