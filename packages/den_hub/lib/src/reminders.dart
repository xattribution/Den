import 'dart:async';

import 'package:den_core/den_core.dart';

import 'config.dart';
import 'context.dart';
import 'hub.dart';

/// A way reminders reach people from the hub: Web Push to the browsers they turned reminders on
/// in. (Phones and computers with the Den app plan their own; Home Assistant gets them through
/// its Den integration, which asks the hub.)
abstract class ReminderSink {
  /// Whether anyone gets reminders this way now.
  bool get active;

  /// Sends [reminder] to the people it is for.
  Future<void> remind(ReminderDue reminder);
}

/// Reminders from the hub: every [HubConfig.reminderInterval] it asks the engine what comes due
/// next and hands each reminder, once (keys kept in the hub's state, so a restart sends none
/// twice), to every [sinks] entry.
class ReminderService implements HubService {
  /// Creates the service for [hub].
  ReminderService(this.hub);

  /// Shared hub context.
  final HubContext hub;

  /// The ways reminders go out (Web Push).
  final List<ReminderSink> sinks = [];

  @override
  String get name => 'Reminders';

  Timer? _timer;
  final Map<String, Timer> _scheduled = {};

  Map<String, Object?> get _sent => hub.state.read('reminders');

  @override
  Future<void> start() async {
    _timer = Timer.periodic(hub.config.reminderInterval, (_) => unawaited(tick()));
    unawaited(tick());
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    for (final t in _scheduled.values) {
      t.cancel();
    }
    _scheduled.clear();
  }

  bool get _configured => sinks.any((s) => s.active);

  /// Looks ahead one interval and schedules what comes due.
  Future<void> tick() async {
    if (!hub.ready || !_configured) return;
    final now = hub.now();
    final from = now - const Duration(minutes: 2).inMilliseconds;
    final to = now + hub.config.reminderInterval.inMilliseconds + 5000;
    final due = await hub.gate.asHub(() => hub.den.remindersDue(from, to));
    _sent.removeWhere((_, at) => at is! int || at < now - const Duration(days: 3).inMilliseconds);
    for (final r in due) {
      if (_sent.containsKey(r.key) || _scheduled.containsKey(r.key)) continue;
      final wait = r.at - now;
      _scheduled[r.key] = Timer(Duration(milliseconds: wait < 0 ? 0 : wait), () => unawaited(_deliver(r)));
    }
  }

  Future<void> _deliver(ReminderDue r) async {
    _scheduled.remove(r.key);
    if (_sent.containsKey(r.key)) return;
    _sent[r.key] = r.at;
    await hub.state.save('reminders');
    for (final sink in sinks) {
      try {
        await sink.remind(r);
      } on Object catch (e) {
        hub.log.warn('A reminder sink failed: ${e.runtimeType}');
      }
    }
  }
}
