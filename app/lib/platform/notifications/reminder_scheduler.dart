import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reminder_plan.dart';

/// Shared-preferences key for local reminders on this device (on unless turned off).
const remindersPrefKey = 'den.reminders';

/// Whether reminders are on for this device: the Settings switch, on until someone turns it off.
Future<bool> remindersEnabled() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(remindersPrefKey) ?? true;
  } on Object {
    return true;
  }
}

/// The OS side of reminders: what [ReminderScheduler] asks of the notification system.
abstract class ReminderOutlet {
  /// Sets the platform up. [onTap] receives the route of a reminder tapped while the app runs.
  /// Returns the route of the reminder that launched the app, if one did.
  Future<String?> start(void Function(String route) onTap);

  /// Hands [reminder] to the OS to show at its time, replacing one with the same id.
  Future<void> schedule(PlannedReminder reminder);

  /// Withdraws a scheduled reminder that hasn't fired.
  Future<void> cancel(int id);

  /// Ids the OS still holds from an earlier run of the app.
  Future<Set<int>> pending();

  /// The same, with the route each one opens (its payload), so a family's can be told apart.
  Future<Map<int, String?>> pendingRoutes();

  /// Asks the person to allow notifications, where the platform asks.
  Future<void> askPermission();
}

/// Keeps this device's OS notifications in step with the family's reminders: plans the next
/// [window] with [planReminders] at start, after every change the engine applies, and every
/// [refresh] while the app runs, then schedules what's new, replaces what changed and withdraws
/// what's gone. A reminder that already fired is left in the notification tray.
///
/// A device in several families has one, over every family's engine ([ReminderScheduler.logs]):
/// one budget of [maxScheduledReminders], nearest first ([planHouseholdReminders]).
class ReminderScheduler {
  ReminderScheduler(
    Den den,
    ReminderOutlet outlet, {
    required bool enabled,
    int Function()? now,
    Duration window = reminderWindow,
    Duration refresh = const Duration(minutes: 30),
    Duration settle = const Duration(milliseconds: 400),
  }) : this.logs(
          () => [ReminderLog(den: den, id: den.familyId ?? '')],
          outlet,
          enabled: enabled,
          now: now,
          window: window,
          refresh: refresh,
          settle: settle,
        );

  /// Reminders across the families [logs] names, read again whenever [logsChanged] fires (a
  /// family joined or left). [unopened] names the families this device holds whose engines
  /// didn't open this time: the reminders the OS holds for them stay as they are (their own
  /// engine plans them when it opens), and the device still counts as in several families.
  ReminderScheduler.logs(
    this._logs,
    this._outlet, {
    required bool enabled,
    Listenable? logsChanged,
    Iterable<String> Function()? unopened,
    int Function()? now,
    this.window = reminderWindow,
    this.refresh = const Duration(minutes: 30),
    this.settle = const Duration(milliseconds: 400),
  })  : _enabled = enabled,
        _logsChanged = logsChanged,
        _unopened = unopened ?? (() => const []),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  List<ReminderLog> Function() _logs;
  Iterable<String> Function() _unopened;
  Listenable? _logsChanged;
  final ReminderOutlet _outlet;
  final int Function() _now;

  /// How far ahead reminders are scheduled.
  final Duration window;

  /// How often the window rolls forward while the app runs.
  final Duration refresh;

  /// How long a burst of changes (a sync, an import) may run before the plan is redone.
  final Duration settle;

  bool _enabled;

  /// The Settings switch "Reminders on this device".
  bool get enabled => _enabled;

  final Map<int, PlannedReminder> _scheduled = {};
  Map<int, String?> _leftover = const {};

  /// What the OS holds for families whose engines didn't open: left alone, and counted against
  /// the budget.
  Set<int> _kept = const {};
  bool _started = false;
  bool _asked = false;
  final List<StreamSubscription<Set<String>>> _changes = [];
  final Set<Den> _following = {};
  Timer? _roll;
  Timer? _soon;
  Future<void>? _running;
  bool _again = false;
  // Single-subscription, so a tap that launched the app waits for the router to listen.
  final _taps = StreamController<String>();

  /// What the OS holds right now, by notification id.
  Map<int, PlannedReminder> get scheduled => Map.unmodifiable(_scheduled);

  /// Routes of tapped reminders, starting with the one that launched the app. One listener: the
  /// app's router.
  Stream<String> get taps => _taps.stream;

  /// Sets the platform up, plans the window and follows the engine from then on. A platform
  /// without notifications leaves reminders off quietly.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final launched = await _outlet.start(_taps.add);
      if (launched != null) _taps.add(launched);
      _leftover = await _outlet.pendingRoutes();
    } on Object catch (e) {
      debugPrint('Reminders are off on this device: $e');
      return;
    }
    _follow();
    _logsChanged?.addListener(_logsMoved);
    _roll = Timer.periodic(refresh, (_) => _later());
    await reschedule();
  }

  /// Follows the families [logs] names from now on, in place of the ones it followed, whenever
  /// [changed] fires: the app's household, once it is open.
  void followLogs(List<ReminderLog> Function() logs, {Listenable? changed, Iterable<String> Function()? unopened}) {
    _logsChanged?.removeListener(_logsMoved);
    _logs = logs;
    _logsChanged = changed;
    if (unopened != null) _unopened = unopened;
    if (!_started) return;
    _logsChanged?.addListener(_logsMoved);
    _logsMoved();
  }

  void _logsMoved() {
    final now = {for (final l in _logs()) l.den};
    if (now.length != _following.length || !now.every(_following.contains)) _follow();
    _later();
  }

  /// Listens to the changes of every family's engine.
  void _follow() {
    for (final s in _changes) {
      unawaited(s.cancel());
    }
    _changes.clear();
    _following.clear();
    for (final log in _logs()) {
      if (!_following.add(log.den)) continue;
      _changes.add(log.den.onChange.listen((_) => _later()));
    }
  }

  /// One plan for a background refresh: no listeners, no timers, and no permission prompt, since
  /// there is no screen to show one on.
  Future<void> runOnce() async {
    _asked = true;
    await _outlet.start((_) {});
    _leftover = await _outlet.pendingRoutes();
    await reschedule();
  }

  /// Turns reminders on this device on or off; off withdraws every one that hasn't fired.
  Future<void> setEnabled(bool on) async {
    _enabled = on;
    if (on) _asked = false;
    if (_started) await reschedule();
  }

  void _later() {
    _soon?.cancel();
    _soon = Timer(settle, () => unawaited(reschedule()));
  }

  /// Plans the window again and brings the OS in line. Calls during a run fold into one more run.
  Future<void> reschedule() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final run = _loop();
    _running = run;
    return run;
  }

  Future<void> _loop() async {
    try {
      do {
        _again = false;
        await _apply();
      } while (_again);
    } finally {
      _running = null;
    }
  }

  Future<void> _apply() async {
    final now = _now();
    final closed = {for (final id in _unopened()) id.toLowerCase()};
    if (_leftover.isNotEmpty) {
      _kept = {
        if (_enabled)
          for (final e in _leftover.entries)
            if (closed.contains(_familyOf(e.value))) e.key,
      };
    }
    if (closed.isEmpty) _kept = const {};
    final want = <int, PlannedReminder>{
      if (_enabled)
        for (final r in planHouseholdReminders(
          _logs(),
          now: now,
          window: window,
          others: closed.length,
          limit: maxScheduledReminders - _kept.length,
          taken: _kept,
        ))
          r.id: r,
    };
    for (final id in _leftover.keys) {
      if (!want.containsKey(id) && !_kept.contains(id)) await _quietly(() => _outlet.cancel(id));
    }
    _leftover = const {};
    for (final entry in _scheduled.entries.toList()) {
      final next = want[entry.key];
      if (next == entry.value) continue;
      // Gone from the plan: withdraw it unless it already fired. Changed: scheduling the new
      // one under the same id replaces it.
      if (next == null && entry.value.at > now) await _quietly(() => _outlet.cancel(entry.key));
      _scheduled.remove(entry.key);
    }
    if (want.isEmpty) return;
    if (!_asked) {
      _asked = true;
      await _quietly(_outlet.askPermission);
    }
    for (final r in want.values) {
      if (_scheduled[r.id] == r) continue;
      if (await _quietly(() => _outlet.schedule(r))) _scheduled[r.id] = r;
    }
  }

  /// The family a reminder's route is in (`/l/<family>/...`), lower case; null for one that
  /// names none.
  static String? _familyOf(String? route) {
    if (route == null || !route.startsWith('/l/')) return null;
    final rest = route.substring(3);
    final end = rest.indexOf(RegExp('[/?]'));
    try {
      return Uri.decodeComponent(end < 0 ? rest : rest.substring(0, end)).toLowerCase();
    } on Object {
      return null;
    }
  }

  static Future<bool> _quietly(Future<void> Function() call) async {
    try {
      await call();
      return true;
    } on Object catch (e) {
      debugPrint('A reminder could not be scheduled: $e');
      return false;
    }
  }

  /// Stops following the engine. Scheduled reminders stay with the OS.
  Future<void> dispose() async {
    _soon?.cancel();
    _roll?.cancel();
    _logsChanged?.removeListener(_logsMoved);
    for (final s in _changes) {
      await s.cancel();
    }
    _changes.clear();
    // Not awaited: with no listener a single-subscription stream never delivers its close.
    unawaited(_taps.close());
  }
}
