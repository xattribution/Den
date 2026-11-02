import 'package:den_core/den_core.dart';

/// The occurrence of [eventId] starting at [at] (UTC ms), or, without [at], the event's first.
/// Null when the event is gone or not shared with this device.
Occurrence? findOccurrence(Den den, String eventId, int? at) {
  final event = den.event(eventId);
  final when = at ?? event?.start;
  if (when == null) return null;
  Occurrence? near;
  for (final occ in den.occurrences(when - 1, when + 1)) {
    if (occ.event.id != eventId) continue;
    if (occ.start == when || occ.seriesStart == when) return occ;
    near ??= occ;
  }
  if (near != null) return near;
  // History links address an occurrence by its place in the series, which it may have moved
  // away from.
  const day = 86400000;
  for (final occ in den.occurrences(when - 3 * day, when + 3 * day)) {
    if (occ.event.id == eventId && occ.seriesStart == when) return occ;
  }
  return null;
}

/// An occurrence made from the event's own fields, for when the asked-for one no longer exists
/// (it moved, or the series changed under it).
Occurrence occurrenceOf(Event event) => Occurrence(
  event: event,
  start: event.start,
  end: event.end,
  title: event.title,
  location: event.location,
  notes: event.notes,
  assignees: event.assignees,
  allDay: event.allDay,
  rides: event.rides,
  reminders: event.reminders,
);
