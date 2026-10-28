import 'package:den_app/platform/notifications/reminder_plan.dart';
import 'package:den_app/platform/notifications/reminder_scheduler.dart';

/// The OS as a map: what it holds, and every call made to it.
class FakeOutlet implements ReminderOutlet {
  final Map<int, PlannedReminder> held = {};
  final List<PlannedReminder> scheduledCalls = [];
  final List<int> cancelled = [];
  Set<int> leftover = {};
  String? launch;
  int asks = 0;
  void Function(String route)? tap;

  @override
  Future<String?> start(void Function(String route) onTap) async {
    tap = onTap;
    return launch;
  }

  @override
  Future<void> schedule(PlannedReminder reminder) async {
    scheduledCalls.add(reminder);
    held[reminder.id] = reminder;
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    held.remove(id);
  }

  @override
  Future<Set<int>> pending() async => {...leftover};

  @override
  Future<void> askPermission() async => asks++;
}
