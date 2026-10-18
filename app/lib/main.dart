import 'dart:async';

import 'package:flutter/material.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'app.dart';
import 'background/background.dart';
import 'boot/boot.dart';
import 'boot/boot_screen.dart';
import 'calendars/device_calendar_source.dart';
import 'calendars/phone_calendars.dart';
import 'capture/capture_service.dart';
import 'capture/capture_settings.dart';
import 'capture/hub_link.dart';
import 'capture/platform_capture.dart';
import 'net/den_network.dart';
import 'net/net_pairing.dart';
import 'net/pairing.dart';
import 'reminders/os_notifications.dart';
import 'reminders/reminder_scheduler.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BootScreen());
  tzdata.initializeTimeZones();
  // A background refresh may have this device's engine open; wait for it to finish.
  final lock = await EngineLock.acquire();
  final den = await Boot.start();
  final network = await DenNetwork.load(den);
  Pairing.service = NetPairing(network);
  Capture.service = CaptureService(settings: await CaptureSettings.load(), hubClient: hubCaptureClient(network));
  final reminders = ReminderScheduler(den, OsNotifications(), enabled: await remindersEnabled());
  final phoneCalendars = PhoneCalendars.supported ? PhoneCalendars(den, DeviceCalendarSource()) : null;
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
