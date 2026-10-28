import 'package:den_actions/times.dart' show dateIn, zoneOfEvent;
import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/actions.dart';
import '../../../app/den_scope.dart';

/// Every change the calendar makes to events (and Today makes to rides), each one a den_actions
/// action. Fields are given the way the engine names them (`start` and `end` in UTC
/// milliseconds, `assignees`, `rrule`, `allDay`, `rides`, `audience`) and said here the way the
/// action takes them.
class EventActions {
  const EventActions(this._actions);

  final AppActions _actions;

  String get _familyZone => _actions.den.family?.timezone ?? 'UTC';

  /// Adds an event with [fields] (`title`, `start` and `end` are required).
  Future<ActionResult> create(Map<String, Object?> fields) {
    final zone = (fields['tz'] as String?) ?? _familyZone;
    return _actions.run('create_event', _args(fields, allDay: fields['allDay'] == true, zone: zone));
  }

  /// Changes [event] by [fields]. On a repeating event [scope] says how far the change reaches
  /// and [occurrence] which one it starts from (its place in the series for one and following;
  /// its start, for all, so the series moves by however far that occurrence moved).
  Future<ActionResult> update(Event event, Map<String, Object?> fields, {EditScope scope = EditScope.all, int? occurrence}) {
    final allDay = (fields['allDay'] as bool?) ?? event.allDay;
    final zone = (fields['tz'] as String?) ?? zoneOfEvent(event, _familyZone);
    return _actions.run('update_event', {
      'event': event.id,
      if (event.rrule != null) 'scope': scope.name,
      if (event.rrule != null) 'occurrence': occurrence,
      ..._args(fields, allDay: allDay, zone: zone),
    });
  }

  /// Removes [event], or on a repeating one the occurrence at [occurrence] ([scope] one) or it
  /// and the ones after (following). Its receipt puts back exactly what was removed.
  Future<ActionResult> delete(Event event, {EditScope scope = EditScope.all, int? occurrence}) =>
      _actions.run('delete_event', {
        'event': event.id,
        if (event.rrule != null) 'scope': scope.name,
        if (event.rrule != null) 'occurrence': occurrence,
      });

  /// Says who drives [occ] there (`to`) or picks up from it (`from`); null for nobody yet.
  Future<ActionResult> setRide(Occurrence occ, String leg, String? driver) => _actions.run('set_ride', {
        'event': occ.event.id,
        'occurrence': occ.seriesStart,
        'leg': leg,
        'driver': driver ?? 'nobody',
      });

  /// [fields] in the action's words. All-day times go as dates: the first day, and the last.
  static Map<String, Object?> _args(Map<String, Object?> fields, {required bool allDay, required String zone}) {
    Object? at(String key, {bool end = false}) {
      final ms = fields[key] as int?;
      if (ms == null) return null;
      return allDay ? dateIn(zone, end ? ms - 1 : ms) : ms;
    }

    final rides = fields['rides'] as List<Ride>?;
    final audience = fields['audience'] as Audience?;
    return {
      if (fields.containsKey('title')) 'title': fields['title'],
      if (fields.containsKey('location')) 'location': fields['location'],
      if (fields.containsKey('notes')) 'notes': fields['notes'],
      if (fields.containsKey('allDay')) 'all_day': fields['allDay'],
      if (fields.containsKey('tz')) 'tz': fields['tz'],
      if (fields.containsKey('start')) 'start': at('start'),
      if (fields.containsKey('end')) 'end': at('end', end: true),
      if (fields.containsKey('rrule')) 'repeat': (fields['rrule'] as String?) ?? 'none',
      if (fields.containsKey('assignees')) 'people': fields['assignees'],
      if (fields.containsKey('category')) 'category': (fields['category'] as String?) ?? '',
      if (fields.containsKey('reminders')) 'reminders': fields['reminders'],
      if (rides != null)
        'rides': [
          for (final r in rides) {'leg': r.leg, 'driver': r.driver ?? 'nobody'},
        ],
      if (fields.containsKey('countdown')) 'countdown': fields['countdown'],
      if (audience != null) 'who_can_see': whoCanSee(audience),
    };
  }
}

extension EventActionsOf on BuildContext {
  /// The calendar's actions. Reading them never rebuilds.
  EventActions get eventActions => EventActions(actions);
}
