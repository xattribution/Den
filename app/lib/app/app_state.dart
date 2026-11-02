import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/layout.dart' show TextSize;
import '../design/tokens.dart' show DenColors;
import '../platform/calendars/phone_calendars.dart';
import '../platform/sync/den_network.dart';
import '../platform/sync/server_setup.dart' show BackupProblem;
import '../platform/notifications/reminder_scheduler.dart';
import '../design/photos.dart';
import '../features/shared_screens/shared_screens.dart' show SignInGuard;
import 'actions.dart';
import 'den_scope.dart';
import 'family_reads.dart';
import 'format.dart';

export 'actions.dart';
export 'den_scope.dart';
export '../design/layout.dart' show TextSize;

/// How this device looks: Day, Night, Auto (Day or Night as the device is), or Soft, the
/// baby-blue and navy theme, light or dark as the device is.
enum ThemeChoice {
  auto,
  day,
  night,
  soft;

  /// The tokens this choice draws by day.
  DenColors get light => this == soft ? DenColors.softDay : DenColors.day;

  /// The tokens this choice draws at night.
  DenColors get dark => this == soft ? DenColors.softNight : DenColors.night;

  /// Whether it follows the device, or keeps to day or to night.
  ThemeMode get mode => switch (this) {
        auto || soft => ThemeMode.system,
        day => ThemeMode.light,
        night => ThemeMode.dark,
      };
}

/// How the calendar's month shows who has something on a day: their dots under the date, or the
/// day itself in their colors. Kept on this device.
enum CalendarDays { dots, colors }

/// What a change can touch besides record types ([RecordType]).
abstract final class Changes {
  /// The theme, the text size, the calendar's look or the wall setting of this device.
  static const prefs = 'prefs';

  /// Everything: the engine itself was swapped (the demo family).
  static const all = 'all';

  /// Who's who and what they may do, which nearly every screen reads: the family's settings,
  /// its people and their photos, its devices, and who is acting on this device.
  static const people = {RecordType.family, RecordType.member, RecordType.photo, RecordType.device, Den.actingChanged};

  /// Which notices this device has shown and its person put away ([AppState.seen]).
  static const notices = 'notices';

  /// What the family's server said about itself ([AppState.backupProblem]).
  static const server = 'server';
}

/// How this device looks and runs, whichever family it shows: Day, Night or Auto, the text
/// size, how the calendar looks, whether it is a wall display (and which view it shows), and
/// whether it shows the screen info over the app. Every family's [AppState] on the device shares one, so a change in one
/// family's Settings is the device's.
class DevicePrefs extends ChangeNotifier {
  DevicePrefs({
    bool wall = false,
    ThemeChoice theme = ThemeChoice.auto,
    TextSize textSize = TextSize.standard,
    CalendarDays calendarDays = CalendarDays.dots,
    bool calendarLight = false,
    bool screenInfo = false,
    String? wallView,
  })  : _wall = wall,
        _theme = theme,
        _textSize = textSize,
        _calendarDays = calendarDays,
        _calendarLight = calendarLight,
        _screenInfo = screenInfo,
        _wallView = wallView;

  static const _wallKey = 'den.wall';
  static const _themeKey = 'den.theme';
  static const _textSizeKey = 'den.textSize';
  static const _calendarDaysKey = 'den.calendarDays';
  static const _calendarLightKey = 'den.calendarLight';
  static const _screenInfoKey = 'den.screenInfo';
  static const _wallViewKey = 'den.wallView';

  /// The saved preferences.
  static Future<DevicePrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    return DevicePrefs(
      wall: prefs.getBool(_wallKey) ?? false,
      theme: ThemeChoice.values.asNameMap()[prefs.getString(_themeKey)] ?? ThemeChoice.auto,
      textSize: TextSize.values.asNameMap()[prefs.getString(_textSizeKey)] ?? TextSize.standard,
      calendarDays: CalendarDays.values.asNameMap()[prefs.getString(_calendarDaysKey)] ?? CalendarDays.dots,
      calendarLight: prefs.getBool(_calendarLightKey) ?? false,
      screenInfo: prefs.getBool(_screenInfoKey) ?? false,
      wallView: prefs.getString(_wallViewKey),
    );
  }

  bool _wall;
  bool get wall => _wall;
  set wall(bool value) {
    if (value == _wall) return;
    _wall = value;
    notifyListeners();
    AppState._save((p) => p.setBool(_wallKey, value));
  }

  ThemeChoice _theme;
  ThemeChoice get theme => _theme;
  set theme(ThemeChoice value) {
    _theme = value;
    notifyListeners();
    AppState._save((p) => p.setString(_themeKey, value.name));
  }

  TextSize _textSize;
  TextSize get textSize => _textSize;
  set textSize(TextSize value) {
    if (value == _textSize) return;
    _textSize = value;
    notifyListeners();
    AppState._save((p) => p.setString(_textSizeKey, value.name));
  }

  CalendarDays _calendarDays;
  CalendarDays get calendarDays => _calendarDays;
  set calendarDays(CalendarDays value) {
    if (value == _calendarDays) return;
    _calendarDays = value;
    notifyListeners();
    AppState._save((p) => p.setString(_calendarDaysKey, value.name));
  }

  bool _calendarLight;
  bool get calendarLight => _calendarLight;
  set calendarLight(bool value) {
    if (value == _calendarLight) return;
    _calendarLight = value;
    notifyListeners();
    AppState._save((p) => p.setBool(_calendarLightKey, value));
  }

  /// Settings → Advanced → Show screen info: the screen's sizes, the keyboard and the last few
  /// viewport events over the app, for reporting a problem with a screenshot. Off by default.
  bool _screenInfo;
  bool get screenInfo => _screenInfo;
  set screenInfo(bool value) {
    if (value == _screenInfo) return;
    _screenInfo = value;
    notifyListeners();
    AppState._save((p) => p.setBool(_screenInfoKey, value));
  }

  /// On a wall display, the view someone there chose with the tabs at its top (`WallView`'s
  /// name: week, today or chores), kept on this device; null follows the layout a parent picked
  /// for the display.
  String? _wallView;
  String? get wallView => _wallView;
  set wallView(String? value) {
    if (value == _wallView) return;
    _wallView = value;
    notifyListeners();
    AppState._save((p) => value == null ? p.remove(_wallViewKey) : p.setString(_wallViewKey, value));
  }
}

/// The app's live state: one family's [Den] engine on this device plus UI preferences. Tells
/// listeners what each change touched ([lastChange]), whether made here or synced from another
/// device, so [DenScope] rebuilds only the widgets that read it.
///
/// A device in several families has one per family (see `household.dart`); they share
/// [DevicePrefs], and each keeps its own notices under [key].
class AppState extends ChangeNotifier with FamilyReads {
  AppState(
    Den den, {
    bool wall = false,
    ThemeChoice theme = ThemeChoice.auto,
    TextSize textSize = TextSize.standard,
    CalendarDays calendarDays = CalendarDays.dots,
    bool calendarLight = false,
    DevicePrefs? device,
    this.network,
    this.reminders,
    this.phoneCalendars,
    Set<String> seen = const {},
    Map<String, int> snoozed = const {},
    String? signInTries,
    String Function(String key)? key,
  })  : _den = den,
        device = device ??
            DevicePrefs(wall: wall, theme: theme, textSize: textSize, calendarDays: calendarDays, calendarLight: calendarLight),
        _key = key ?? _same,
        _seen = {...seen},
        _snoozed = {...snoozed} {
    signInGuard = SignInGuard.fromJson(
      signInTries,
      now: () => _den.now(),
      onChange: (json) => _save((p) => p.setString(_key(_signInTriesKey), json)),
    );
    this.device.addListener(_prefsChanged);
    _listen();
    _keepPhotos();
  }

  static String _same(String key) => key;

  /// Restores the saved theme, text size, calendar and wall preferences for this device (or
  /// shares [device]'s), and this family's notices kept under [key] (Den's own names for the
  /// first family).
  static Future<AppState> load(
    Den den, {
    DenNetwork? network,
    ReminderScheduler? reminders,
    PhoneCalendars? phoneCalendars,
    DevicePrefs? device,
    String Function(String key)? key,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final k = key ?? _same;
    return AppState(
      den,
      device: device ?? await DevicePrefs.load(),
      seen: {...?prefs.getStringList(k(_seenKey))},
      snoozed: _readSnoozed(prefs.getStringList(k(_snoozedKey))),
      signInTries: prefs.getString(k(_signInTriesKey)),
      network: network,
      reminders: reminders,
      phoneCalendars: phoneCalendars,
      key: key,
    );
  }

  /// Deletes this family's notices from the device (a family it left), as kept under [key].
  static Future<void> forget(String Function(String key) key) async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in const [_seenKey, _snoozedKey, _signInTriesKey]) {
      await prefs.remove(key(k));
    }
  }

  /// How this device looks and runs, shared by every family on it.
  final DevicePrefs device;

  /// This family's name for one of this device's settings.
  final String Function(String key) _key;

  /// This device's sync with the hub and other devices; null for the demo family and in tests.
  final DenNetwork? network;

  /// This device's reminder notifications; null in tests. It follows the device's own engine,
  /// never the demo family's.
  final ReminderScheduler? reminders;

  /// Calendars brought in from this phone; null where there are none to bring in, and in tests.
  final PhoneCalendars? phoneCalendars;

  static const _seenKey = 'den.seen';
  static const _snoozedKey = 'den.snoozed';
  static const _signInTriesKey = 'den.signInTries';

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
    _keepPhotos();
    _changed(const {Changes.all});
  }

  /// Why the server's last backup didn't happen or didn't reach the NAS, as the server said it to
  /// this phone (a parent of the server's own family, on their own phone), or null. Kept in
  /// memory only; Today asks again (settings/state/server_watch.dart).
  BackupProblem? get backupProblem => _backupProblem;
  BackupProblem? _backupProblem;
  set backupProblem(BackupProblem? p) {
    if (p?.kind == _backupProblem?.kind && p?.at == _backupProblem?.at && p?.place == _backupProblem?.place) return;
    _backupProblem = p;
    _changed(const {Changes.server});
  }

  /// Whether the family's server said this family is its own (its parents see Backups), once
  /// it has said.
  bool get serverFamily => _serverFamily;
  bool _serverFamily = false;
  set serverFamily(bool on) {
    if (on == _serverFamily) return;
    _serverFamily = on;
    _changed(const {Changes.server});
  }

  /// Notices (a privacy change, a sitter's access ending) this device's person put away with
  /// "Got it", by key. Kept on this device only.
  bool seen(String key) => _seen.contains(key);
  final Set<String> _seen;

  /// Puts a notice away for good on this device.
  void markSeen(String key) {
    if (!_seen.add(key)) return;
    _changed(const {Changes.notices});
    final keep = [..._seen];
    _save((p) => p.setStringList(_key(_seenKey), keep.length > 200 ? keep.sublist(keep.length - 200) : keep));
  }

  /// Until when (UTC milliseconds) a reminder this device's person put off ("Remind me later") stays
  /// away, by key, or null. Kept on this device only.
  int? snoozedUntil(String key) => _snoozed[key];
  final Map<String, int> _snoozed;

  /// Puts a reminder off until [until] (UTC milliseconds) on this device. Whatever was put off
  /// until a time already past is forgotten.
  void snooze(String key, int until) {
    final now = _den.now();
    _snoozed.removeWhere((k, at) => k != key && at <= now);
    _snoozed[key] = until;
    _savedSnoozed();
  }

  /// How many things put off on this device have come back by [now]: it changes the moment one
  /// does, so what reads them can look again.
  int snoozesEnded(int now) => _snoozed.values.where((until) => until <= now).length;

  /// Takes back [snooze] for [key] (Undo).
  void unsnooze(String key) {
    if (_snoozed.remove(key) == null) return;
    _savedSnoozed();
  }

  void _savedSnoozed() {
    _changed(const {Changes.notices});
    final keep = [for (final e in _snoozed.entries) '${e.value} ${e.key}'];
    _save((p) => p.setStringList(_key(_snoozedKey), keep));
  }

  static Map<String, int> _readSnoozed(List<String>? kept) => {
        for (final line in kept ?? const <String>[])
          if (line.indexOf(' ') case final space when space > 0 && int.tryParse(line.substring(0, space)) != null)
            line.substring(space + 1): int.parse(line.substring(0, space)),
      };

  /// Wrong PINs and patterns on this device, per person, and how long the next try waits; kept
  /// on this device, so restarting Den doesn't reset it.
  late final SignInGuard signInGuard;

  /// Decodes the photos people's pictures name, so avatars draw them in their first frame.
  void _keepPhotos() {
    final den = _den;
    DenPhotos.keep([
      for (final m in den.members)
        if (m.photo case final id?) ?den.photo(id),
    ]);
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

  void _prefsChanged() => _changed(const {Changes.prefs});

  /// Running as a shared wall display: larger type, the week grid first, "who's doing this?".
  bool get wall => device.wall;
  set wall(bool value) => device.wall = value;

  ThemeChoice get theme => device.theme;
  set theme(ThemeChoice value) => device.theme = value;

  /// How much larger than the system's this device draws text (Settings, Appearance). A Home
  /// Screen web app never hears the iPhone's own Text Size, so this is how it gets larger there.
  TextSize get textSize => device.textSize;
  set textSize(TextSize value) => device.textSize = value;

  /// Whether the calendar's month shows people's dots under each day or the day in their colors
  /// (the calendar's view options, and Settings, Appearance).
  CalendarDays get calendarDays => device.calendarDays;
  set calendarDays(CalendarDays value) => device.calendarDays = value;

  /// Whether the calendar stays light while the rest of the app is dark (Settings, Appearance:
  /// "Calendar: Always light"); otherwise it matches the app.
  bool get calendarLight => device.calendarLight;
  set calendarLight(bool value) => device.calendarLight = value;

  StreamSubscription<Set<String>>? _sub;
  Formats? _formats;

  void _listen() {
    _sub = _den.onChange.listen((types) {
      if (types.contains(RecordType.family)) _formats = null;
      if (types.contains(RecordType.member) || types.contains(RecordType.photo)) _keepPhotos();
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
    device.removeListener(_prefsChanged);
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
