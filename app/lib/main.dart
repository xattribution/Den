import 'dart:async';

import 'package:flutter/material.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'app/den_app.dart';
import 'platform/background/background.dart';
import 'platform/storage/boot.dart';
import 'app/boot_screen.dart';
import 'app/other_tab_screen.dart';
import 'platform/calendars/device_calendar_source.dart';
import 'platform/calendars/phone_calendars.dart';
import 'platform/capture/platform_capture.dart';
import 'platform/sync/den_network.dart';
import 'platform/sync/net_pairing.dart';
import 'platform/sync/pairing.dart';
import 'platform/notifications/os_notifications.dart';
import 'platform/notifications/reminder_scheduler.dart';
import 'app/app_state.dart';
import 'platform/web/web_app.dart';
import 'platform/capabilities.dart';
import 'features/add/add.dart';
import 'features/family/family.dart' show RecoveryNotices;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BootScreen());
  tzdata.initializeTimeZones();
  // A background refresh may have this device's engine open; wait for it to finish.
  final lock = await EngineLock.acquire();
  if (Capabilities.web) {
    // Tabs of one browser share the family's log; one at a time writes it.
    if (!await WebApp.holdEngine()) {
      runApp(const OtherTabScreen());
      await WebApp.waitForEngine();
      runApp(const BootScreen());
    }
    unawaited(WebApp.persist());
  }
  final den = await Boot.start();
  final network = await DenNetwork.load(den);
  Pairing.service = NetPairing(network);
  Capture.service = CaptureService(settings: await CaptureSettings.load(), hubClient: hubCaptureClient(network));
  final reminders = ReminderScheduler(den, OsNotifications(), enabled: await remindersEnabled());
  final phoneCalendars = PhoneCalendars.supported ? PhoneCalendars(den, DeviceCalendarSource()) : null;
  await RecoveryNotices.load();
  runApp(DenApp(
    state: await AppState.load(den, network: network, reminders: reminders, phoneCalendars: phoneCalendars),
  ));
  unawaited(network.start());
  unawaited(reminders.start());
  unawaited(phoneCalendars?.start());
  // While the app runs, a background refresh asks it to do the work with its own engine.
  lock.onRefresh = () async {
    await reminders.reschedule();
    await phoneCalendars?.sync();
  };
  unawaited(scheduleBackgroundRefresh());
  // Shares that opened Den, that arrive while it's open, and that waited while it was away.
  unawaited(Capture.collectShares());
  const PlatformCapture().sharesArrived.listen((_) => Capture.collectShares());
  AppLifecycleListener(onResume: Capture.collectShares);
}
