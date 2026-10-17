import 'model.dart';
import 'rrule.dart';
import 'time.dart';
import 'views.dart';

/// Whether a chore's schedule puts it on [date].
bool scheduledOn(Chore chore, String date) {
  final schedule = chore.schedule;
  if (schedule.once != null) return schedule.once == date;
  final start = schedule.start!;
  if (!isLocalDate(start) || date.compareTo(start) < 0) return false;
  final RecurrenceRule rule;
  try {
    rule = RecurrenceRule.parse(schedule.rrule!);
  } on FormatException {
    return false;
  }
  final target = dateToWall(date);
  for (final day in rule.expand(dateToWall(start), from: target)) {
    if (day == target) return true;
    if (day.isAfter(target)) return false;
  }
  return false;
}

/// Who a rotation puts on [date]: periods since the anchor, modulo the number of people.
String? rotationOwner(OwnerRotation rotation, String date, int weekStart) {
  if (rotation.ids.isEmpty || !isLocalDate(rotation.anchor)) return null;
  final periods = rotation.every == 'day'
      ? daysBetween(rotation.anchor, date)
      : daysBetween(startOfWeek(rotation.anchor, weekStart), startOfWeek(date, weekStart)) ~/ 7;
  return rotation.ids[periods % rotation.ids.length];
}

/// The chore's owner on [date] before any swap; null means anyone.
String? scheduledOwner(Chore chore, String date, int weekStart) => switch (chore.owner) {
      OwnerMember(:final id) => id,
      OwnerAnyone() => null,
      final OwnerRotation r => rotationOwner(r, date, weekStart),
    };

/// Whether the completion swapped the chore for its day. A swap to anyone stores a null owner,
/// so the field's presence is what marks a swap.
bool isSwapped(Completion? completion) => completion?.rec.fields.containsKey('owner') ?? false;

/// The chore's owner on [date] after a one-day swap; null means anyone.
String? dayOwner(Chore chore, String date, Completion? completion, int weekStart) =>
    isSwapped(completion) ? completion!.owner : scheduledOwner(chore, date, weekStart);

/// Done when marked done, or when it has steps and every one is checked.
bool isDone(Chore chore, Completion? completion) {
  if (completion == null) return false;
  if (completion.done) return true;
  final steps = chore.steps;
  if (steps.isEmpty) return false;
  final checked = completion.steps;
  return steps.every((s) => checked[s.id] != null);
}

/// The chore as it stands on [date]. [today] and [nowMinutes] (minutes after local midnight)
/// decide whether it's late.
ChoreDay choreDay({
  required Chore chore,
  required String date,
  required Completion? completion,
  required int weekStart,
  required String today,
  required int nowMinutes,
}) {
  final done = isDone(chore, completion);
  final due = chore.dueTime;
  final late = !done &&
      (date.compareTo(today) < 0 ||
          (date == today && due != null && isLocalTime(due) && nowMinutes > minutesOf(due)));
  return ChoreDay(
    chore: chore,
    date: date,
    owner: dayOwner(chore, date, completion, weekStart),
    done: done,
    doneBy: completion?.doneBy,
    steps: {for (final s in chore.steps) s.id: completion?.steps[s.id]},
    late: late,
  );
}
