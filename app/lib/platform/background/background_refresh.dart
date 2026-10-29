import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show SyncState;
import 'package:flutter/foundation.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:workmanager/workmanager.dart';

import '../storage/boot.dart';
import '../storage/memberships.dart';
import '../calendars/device_calendar_source.dart';
import '../calendars/phone_calendars.dart';
import '../sync/den_network.dart';
import '../notifications/os_notifications.dart';
import '../notifications/reminder_plan.dart';
import '../notifications/reminder_scheduler.dart';
import 'engine_lock.dart';
import '../capabilities.dart';

export 'engine_lock.dart' show EngineLock;

/// The background task's name, which is also its iOS BGTaskScheduler identifier (listed in
/// Info.plist and registered in AppDelegate.swift).
const backgroundRefreshTask = 'family.den.refresh';

/// How often the OS is asked to run it. Android runs it about this often; iOS treats it as the
/// earliest next run and decides from how the phone is used.
const backgroundRefreshEvery = Duration(hours: 1);

/// The phones that run it: Android (WorkManager) and iOS (BGAppRefreshTask). Desktops and
/// displays keep Den open, which refreshes on its own timers.
bool get backgroundRefreshSupported =>
    Capabilities.backgroundRefresh;

/// Asks the OS to run [refreshInBackground] every [backgroundRefreshEvery], keeping one task.
Future<void> scheduleBackgroundRefresh() async {
  if (!backgroundRefreshSupported) return;
  try {
    await Workmanager().initialize(backgroundRefreshDispatcher);
    await Workmanager().registerPeriodicTask(
      backgroundRefreshTask,
      backgroundRefreshTask,
      frequency: backgroundRefreshEvery,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  } on Object catch (e) {
    debugPrint('Background refresh could not be scheduled: $e');
  }
}

/// Where the OS enters Dart for the background task.
@pragma('vm:entry-point')
void backgroundRefreshDispatcher() {
  Workmanager().executeTask((task, input) => refreshInBackground());
}

/// The background task. When the app is running it holds the engines, so the task asks it to
/// refresh. Otherwise the task opens every family's engine on this device itself: catches up
/// with each family for a few seconds, brings in the phone's calendars, plans the next reminders
/// across all of them, and closes it all again. It reports success either way, so the OS keeps
/// scheduling it; a pass that failed is simply done again next time.
Future<bool> refreshInBackground() async {
  final lock = await EngineLock.tryAcquire();
  if (lock == null) {
    await EngineLock.askHolderToRefresh();
    return true;
  }
  final open = <RefreshLog>[];
  try {
    tzdata.initializeTimeZones();
    final listed = await Memberships.load();
    if (listed.isEmpty) {
      open.add(RefreshLog(await Boot.start(background: true)));
    } else {
      for (final m in listed) {
        try {
          open.add(RefreshLog(await Boot.startLog(m, background: true), log: m));
        } on Object catch (e) {
          // That family's keys can't be read yet (a locked phone): the others go on.
          debugPrint('The background refresh left out ${m.label ?? m.id}: $e');
        }
      }
    }
    await BackgroundRefresh.logs(
      open,
      outlet: OsNotifications(),
      calendars: PhoneCalendars.supported ? DeviceCalendarSource() : null,
      connect: connectBriefly,
    ).run();
  } on Object catch (e) {
    debugPrint('The background refresh stopped early: $e');
  } finally {
    for (final l in open) {
      await l.den.close();
    }
    lock.release();
  }
  return true;
}

/// One family's engine in a background pass, and where the device keeps it ([log], null for the
/// first family as Den always kept it).
class RefreshLog {
  const RefreshLog(this.den, {this.log});

  final Den den;
  final Membership? log;

  /// Whether this is the first family's, whose reminders keep their ids and which brings in the
  /// phone's own calendars.
  bool get first => log == null || log!.primary;
}

/// Ends a short connection to the family, after letting what this device wrote go out.
typedef Disconnect = Future<void> Function();

/// One background pass over the open engines, in the order that makes each step's input fresh:
/// what each family changed comes in first (all at once), then the phone's calendars, then the
/// reminders are planned from all of it, one budget across every family.
class BackgroundRefresh {
  BackgroundRefresh(
    Den den, {
    required ReminderOutlet outlet,
    PhoneCalendarSource? calendars,
    Future<Disconnect?> Function(Den den)? connect,
    Duration connectLimit = const Duration(seconds: 20),
    int Function()? now,
  }) : this.logs(
          [RefreshLog(den)],
          outlet: outlet,
          calendars: calendars,
          connect: connect == null ? null : (den, {log}) => connect(den),
          connectLimit: connectLimit,
          now: now,
        );

  BackgroundRefresh.logs(
    this.engines, {
    required this.outlet,
    this.calendars,
    this.connect,
    this.connectLimit = const Duration(seconds: 20),
    int Function()? now,
  }) : _now = now;

  /// Every family's engine, the first family's first.
  final List<RefreshLog> engines;

  /// The first family's engine, which the phone's calendars come into.
  Den get den => engines.firstWhere((l) => l.first, orElse: () => engines.first).den;

  final ReminderOutlet outlet;

  /// This phone's calendars, where it has them to bring in.
  final PhoneCalendarSource? calendars;

  /// Connects to a family and returns once caught up (or after trying for a while), with the
  /// way to disconnect; null when there is nobody to connect to.
  final Future<Disconnect?> Function(Den den, {Membership? log})? connect;

  /// The most [connect] may take before the pass goes on without it; iOS gives a background
  /// refresh about 30 seconds in all.
  final Duration connectLimit;
  final int Function()? _now;

  Future<void> run() async {
    final live = [for (final l in engines) if (l.den.hasFamily && l.den.isApproved) l];
    if (live.isEmpty) return;
    final disconnects = await Future.wait([
      for (final l in live) _guard('Syncing', () async => connect?.call(l.den, log: l.log).timeout(connectLimit)),
    ]);
    try {
      final source = calendars;
      final first = live.where((l) => l.first).firstOrNull;
      if (source != null && first != null) {
        final den = first.den;
        await _guard('Bringing in phone calendars', () async {
          final phone = PhoneCalendars(den, source, now: _now);
          await phone.load();
          if (phone.picks.isNotEmpty) await phone.sync();
          phone.dispose();
        });
      }
      await _guard('Planning reminders', () async {
        final logs = [
          for (final l in live)
            ReminderLog(den: l.den, id: l.den.familyId ?? '', label: l.den.family?.name, first: l.first),
        ];
        final reminders = ReminderScheduler.logs(() => logs, outlet, enabled: await remindersEnabled(), now: _now);
        await reminders.runOnce();
        await reminders.dispose();
      });
    } finally {
      for (final disconnect in disconnects) {
        await _guard('Disconnecting', () async => disconnect?.call());
      }
    }
  }

  static Future<T?> _guard<T>(String step, Future<T> Function() work) async {
    try {
      return await work();
    } on Object catch (e) {
      debugPrint('Background refresh: $step failed: $e');
      return null;
    }
  }
}

/// Connects this device to a family's hub (on the home network or through the relay) and gives it
/// [wait] in all to find the hub and catch up. The hub itself skips it, and so does a device
/// that found no hub to try, so a pass with nothing to sync ends in a few seconds. Disconnecting first gives
/// what this pass wrote [flush] to go out.
Future<Disconnect?> connectBriefly(
  Den den, {
  Membership? log,
  Duration wait = const Duration(seconds: 12),
  Duration flush = const Duration(seconds: 2),
}) async {
  final network = await DenNetwork.load(den, log: log == null || log.primary ? null : log);
  if (network.isHub) {
    await network.close();
    return null;
  }
  final until = DateTime.now().add(wait);
  final caughtUp = Completer<void>();
  void check() {
    if (network.status.state == SyncState.live && !caughtUp.isCompleted) caughtUp.complete();
  }

  network.addListener(check);
  await network.start().timeout(wait, onTimeout: () {});
  check();
  // With no hub found there is nothing to wait for.
  final left = until.difference(DateTime.now());
  if (network.connecting && left > Duration.zero) await caughtUp.future.timeout(left, onTimeout: () {});
  network.removeListener(check);
  return () async {
    if (network.status.state == SyncState.live) await Future<void>.delayed(flush);
    await network.close();
  };
}
