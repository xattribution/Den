import 'dart:math' as math;

import 'package:den_core/den_core.dart';

import '../../../app/format.dart';
import '../words/block_words.dart';

/// Events on one day that go together in the list: everything that happens at the same time
/// (overlapping, directly or through a chain), or the day's all-day events. A group of more than
/// one stacks its blocks, and can be combined into one.
class DayGroup {
  DayGroup({required this.date, required this.time, required this.items});

  final String date;

  /// The time column's words ("3:30 PM", "Until 11:00 AM"), or null for all day.
  final String? time;
  final List<Occurrence> items;

  bool get isMulti => items.length > 1;

  /// Stays the same while the group starts with the same event, so a combined group stays
  /// combined through changes elsewhere.
  String get key => '$date:${items.first.event.id}:${items.first.start}';
}

/// [occurrences] on [date] (sorted for the day, see compareForDay) in groups: the all-day ones
/// first, then each run of events that overlap.
List<DayGroup> groupDay(List<Occurrence> occurrences, Formats f, String date) {
  final allDay = <Occurrence>[];
  final groups = <DayGroup>[];
  List<Occurrence>? run;
  String? runTime;
  var runEnd = 0;

  void close() {
    if (run != null) groups.add(DayGroup(date: date, time: runTime, items: run!));
    run = null;
  }

  for (final occ in occurrences) {
    final time = blockTime(f, occ, date);
    if (time == null) {
      allDay.add(occ);
      continue;
    }
    final startsHere = f.localDate(occ.start) == date;
    if (!startsHere) {
      // The last day of something longer: its own line, at the top of the day.
      close();
      groups.add(DayGroup(date: date, time: time, items: [occ]));
      continue;
    }
    final end = math.max(occ.end, occ.start + 60000);
    if (run != null && occ.start < runEnd) {
      run!.add(occ);
      runEnd = math.max(runEnd, end);
    } else {
      close();
      run = [occ];
      runTime = time;
      runEnd = end;
    }
  }
  close();
  return [if (allDay.isNotEmpty) DayGroup(date: date, time: null, items: allDay), ...groups];
}
