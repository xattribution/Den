import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'reminder_plan.dart';
import 'reminder_scheduler.dart';

/// Reminders through the platform's own notifications (flutter_local_notifications). Android,
/// iOS, macOS and Windows hold scheduled notifications themselves, so they fire with the app
/// closed; Linux has no scheduler, so there a timer shows each one while the app runs. The
/// payload is the route a tap opens.
class OsNotifications implements ReminderOutlet {
  OsNotifications([FlutterLocalNotificationsPlugin? plugin]) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final Map<int, Timer> _timers = {};
  AndroidScheduleMode _androidMode = AndroidScheduleMode.inexactAllowWhileIdle;

  static bool get _osSchedules => switch (defaultTargetPlatform) {
        TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.macOS || TargetPlatform.windows => true,
        _ => false,
      };

  static const _android = AndroidNotificationDetails(
    'reminders',
    'Reminders',
    channelDescription: 'Events and chores coming up',
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.reminder,
  );

  static const _details = NotificationDetails(
    android: _android,
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
    windows: WindowsNotificationDetails(),
  );

  @override
  Future<String?> start(void Function(String route) onTap) async {
    if (kIsWeb) throw UnsupportedError('Browsers can\'t schedule notifications');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
        iOS: darwin,
        macOS: darwin,
        linux: LinuxInitializationSettings(defaultActionName: 'Open Den'),
        windows: WindowsInitializationSettings(
          appName: 'Den',
          appUserModelId: 'Den.Family.App',
          guid: '6f1d0e4c-3b7a-4f53-9a8e-2c5d7b1e9f40',
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        final route = response.payload;
        if (route != null && route.startsWith('/')) onTap(route);
      },
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null && (await android.canScheduleExactNotifications() ?? false)) {
      _androidMode = AndroidScheduleMode.exactAllowWhileIdle;
    }
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final route = launch?.didNotificationLaunchApp == true ? launch?.notificationResponse?.payload : null;
    return route != null && route.startsWith('/') ? route : null;
  }

  @override
  Future<void> askPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, sound: true);
    await _plugin
        .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, sound: true);
  }

  @override
  Future<void> schedule(PlannedReminder reminder) async {
    final wait = reminder.at - DateTime.now().millisecondsSinceEpoch;
    if (!_osSchedules || wait < 2000) {
      _timers.remove(reminder.id)?.cancel();
      _timers[reminder.id] = Timer(Duration(milliseconds: wait < 0 ? 0 : wait), () {
        _timers.remove(reminder.id);
        unawaited(_show(reminder));
      });
      return;
    }
    await _plugin.zonedSchedule(
      id: reminder.id,
      scheduledDate: tz.TZDateTime.fromMillisecondsSinceEpoch(tz.UTC, reminder.at),
      notificationDetails: _details,
      androidScheduleMode: _androidMode,
      title: reminder.title,
      body: reminder.body.isEmpty ? null : reminder.body,
      payload: reminder.route,
    );
  }

  Future<void> _show(PlannedReminder reminder) => _plugin.show(
        id: reminder.id,
        title: reminder.title,
        body: reminder.body.isEmpty ? null : reminder.body,
        notificationDetails: _details,
        payload: reminder.route,
      );

  @override
  Future<void> cancel(int id) async {
    _timers.remove(id)?.cancel();
    if (_osSchedules) await _plugin.cancel(id: id);
  }

  @override
  Future<Set<int>> pending() async {
    if (!_osSchedules) return {};
    final requests = await _plugin.pendingNotificationRequests();
    return {for (final r in requests) r.id};
  }
}
