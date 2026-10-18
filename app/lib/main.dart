import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'app.dart';
import 'boot/boot.dart';
import 'boot/boot_screen.dart';
import 'calendars/device_calendar_source.dart';
import 'calendars/phone_calendars.dart';
import 'net/den_network.dart';
import 'net/net_pairing.dart';
import 'net/pairing.dart';
import 'reminders/os_notifications.dart';
import 'reminders/reminder_scheduler.dart';
import 'screens/settings/settings_screen.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BootScreen());
  tzdata.initializeTimeZones();
  final den = await Boot.start();
  final network = await DenNetwork.load(den);
  Pairing.service = NetPairing(network);
  final reminders = ReminderScheduler(den, OsNotifications(), enabled: await _remindersOn());
  final phoneCalendars = PhoneCalendars.supported ? PhoneCalendars(den, DeviceCalendarSource()) : null;
  runApp(DenApp(
    state: await AppState.load(den, network: network, reminders: reminders, phoneCalendars: phoneCalendars),
  ));
  unawaited(network.start());
  unawaited(reminders.start());
  unawaited(phoneCalendars?.start());
}

Future<bool> _remindersOn() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(remindersPrefKey) ?? true;
  } on Object {
    return true;
  }
}
