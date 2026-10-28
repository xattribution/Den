import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show SyncState;
import 'package:flutter/foundation.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:workmanager/workmanager.dart';

import '../storage/boot.dart';
import '../calendars/device_calendar_source.dart';
import '../calendars/phone_calendars.dart';
import '../sync/den_network.dart';
import '../notifications/os_notifications.dart';
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

/// The background task. When the app is running it holds the engine, so the task asks it to
/// refresh. Otherwise the task opens this device's engine itself: catches up with the family
/// for a few seconds, brings in the phone's calendars, plans the next reminders, and closes it
/// all again. It reports success either way, so the OS keeps scheduling it; a pass that failed
/// is simply done again next time.
Future<bool> refreshInBackground() async {
  final lock = await EngineLock.tryAcquire();
  if (lock == null) {
    await EngineLock.askHolderToRefresh();
    return true;
  }
  try {
    tzdata.initializeTimeZones();
    final den = await Boot.start(background: true);
    try {
      await BackgroundRefresh(
        den,
        outlet: OsNotifications(),
        calendars: PhoneCalendars.supported ? DeviceCalendarSource() : null,
        connect: connectBriefly,
      ).run();
    } finally {
      await den.close();
    }
  } on Object catch (e) {
    debugPrint('The background refresh stopped early: $e');
  } finally {
    lock.release();
  }
  return true;
}

/// Ends a short connection to the family, after letting what this device wrote go out.
typedef Disconnect = Future<void> Function();

/// One background pass over an open engine, in the order that makes each step's input fresh:
/// what the family changed comes in first, then the phone's calendars, then the reminders are
/// planned from all of it.
class BackgroundRefresh {
  BackgroundRefresh(
    this.den, {
    required this.outlet,
    this.calendars,
    this.connect,
    this.connectLimit = const Duration(seconds: 20),
    int Function()? now,
  }) : _now = now;

  final Den den;
  final ReminderOutlet outlet;

  /// This phone's calendars, where it has them to bring in.
  final PhoneCalendarSource? calendars;

  /// Connects to the family and returns once caught up (or after trying for a while), with the
  /// way to disconnect; null when there is nobody to connect to.
  final Future<Disconnect?> Function(Den den)? connect;

  /// The most [connect] may take before the pass goes on without it; iOS gives a background
  /// refresh about 30 seconds in all.
  final Duration connectLimit;
  final int Function()? _now;

  Future<void> run() async {
    if (!den.hasFamily || !den.isApproved) return;
    final disconnect = await _guard('Syncing', () async => connect?.call(den).timeout(connectLimit));
    try {
      final source = calendars;
      if (source != null) {
        await _guard('Bringing in phone calendars', () async {
          final phone = PhoneCalendars(den, source, now: _now);
          await phone.load();
          if (phone.picks.isNotEmpty) await phone.sync();
          phone.dispose();
        });
      }
      await _guard('Planning reminders', () async {
        final reminders = ReminderScheduler(den, outlet, enabled: await remindersEnabled(), now: _now);
        await reminders.runOnce();
        await reminders.dispose();
      });
    } finally {
      await _guard('Disconnecting', () async => disconnect?.call());
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

/// Connects this device to its hub (on the home network or through the relay) and gives it
/// [wait] in all to find the hub and catch up. The hub itself skips it, and so does a device
/// that found no hub to try, so a pass with nothing to sync ends in a few seconds. Disconnecting first gives
/// what this pass wrote [flush] to go out.
Future<Disconnect?> connectBriefly(
  Den den, {
  Duration wait = const Duration(seconds: 12),
  Duration flush = const Duration(seconds: 2),
}) async {
  final network = await DenNetwork.load(den);
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
