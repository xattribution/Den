import 'dart:async';

import 'package:flutter/material.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'app/den_app.dart';
import 'app/household.dart';
import 'platform/background/background.dart';
import 'app/boot_screen.dart';
import 'app/other_tab_screen.dart';
import 'platform/capture/platform_capture.dart';
import 'platform/notifications/reminder_plan.dart';
import 'platform/sync/pairing.dart';
import 'platform/notifications/os_notifications.dart';
import 'platform/notifications/reminder_scheduler.dart';
import 'app/app_state.dart';
import 'platform/web/web_app.dart';
import 'platform/capabilities.dart';
import 'features/add/add.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BootScreen());
  tzdata.initializeTimeZones();
  // A background refresh may have this device's engines open; wait for it to finish. One lock
  // covers every family on the device.
  final lock = await EngineLock.acquire();
  if (Capabilities.web) {
    // Tabs of one browser share the families' logs; one at a time writes them.
    if (!await WebApp.holdEngine()) {
      runApp(const OtherTabScreen());
      await WebApp.waitForEngine();
      runApp(const BootScreen());
    }
    unawaited(WebApp.persist());
  }
  // Every family on this device, each with its own engine, keys and connection.
  final device = await DevicePrefs.load();
  final reminders = ReminderScheduler.logs(() => const [], OsNotifications(), enabled: await remindersEnabled());
  final household = await Household.boot(DeviceHouseholdStore(device: device, reminders: reminders, phoneCalendars: true));
  // One budget of reminders across every family, followed as families join and leave.
  reminders.followLogs(
    () => [
      for (final l in household.logs)
        ReminderLog(den: l.den, id: l.id, label: l.name, first: l.membership.primary),
    ],
    changed: household,
  );
  Pairing.service = household.active.pairing ?? const LocalOnlyPairing();
  Capture.service = CaptureService(
    settings: await CaptureSettings.load(),
    hubClient: hubCaptureClientOf(() => household.active.network),
  );
  runApp(DenApp(household: household));
  for (final log in household.logs) {
    unawaited(log.network?.start());
    unawaited(log.state.phoneCalendars?.start());
  }
  unawaited(reminders.start());
  // While the app runs, a background refresh asks it to do the work with its own engines.
  lock.onRefresh = () async {
    await reminders.reschedule();
    for (final log in household.logs) {
      await log.state.phoneCalendars?.sync();
    }
  };
  unawaited(scheduleBackgroundRefresh());
  // Shares that opened Den, that arrive while it's open, and that waited while it was away.
  unawaited(Capture.collectShares());
  const PlatformCapture().sharesArrived.listen((_) => Capture.collectShares());
  AppLifecycleListener(onResume: Capture.collectShares);
}
