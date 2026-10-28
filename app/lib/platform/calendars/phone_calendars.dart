import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import '../capabilities.dart';

/// A calendar on this phone, as the OS lists it.
class PhoneCalendar {
  const PhoneCalendar({required this.id, required this.name, this.account = ''});
  final String id;
  final String name;

  /// The account that holds it ("iCloud", "jo@example.com"); empty for the phone itself.
  final String account;
}

/// One occurrence of an event on this phone. A repeating event arrives as one per occurrence,
/// each with its own [instanceId].
class PhoneEvent {
  const PhoneEvent({
    required this.calendarId,
    required this.instanceId,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.notes = '',
    this.location = '',
    this.timeZone,
    this.cancelled = false,
  });

  final String calendarId;

  /// The OS event id, or `eventId@timestamp` for an occurrence of a repeating event.
  final String instanceId;
  final String title;

  /// Instants for a timed event; floating local dates (midnight) for an all-day one, the end
  /// being the day after the last.
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String notes;
  final String location;
  final String? timeZone;
  final bool cancelled;
}

/// Whether Den may read this phone's calendars.
enum PhoneAccess {
  granted,

  /// Not asked yet, or asked and declined in a way the OS lets the app ask again.
  ask,

  /// Declined for good: only the phone's Settings can change it.
  denied,

  /// Blocked by Screen Time or a device policy.
  restricted,
}

/// The OS side of phone calendars.
abstract class PhoneCalendarSource {
  Future<PhoneAccess> access();
  Future<PhoneAccess> requestAccess();
  Future<void> openSettings();
  Future<List<PhoneCalendar>> calendars();

  /// Occurrences in [from, to) from [calendarIds].
  Future<List<PhoneEvent>> events(List<String> calendarIds, DateTime from, DateTime to);
}

/// What one pass of [PhoneCalendars.sync] did.
class PhoneSyncResult {
  const PhoneSyncResult({this.added = 0, this.updated = 0, this.removed = 0});
  final int added;
  final int updated;
  final int removed;
  @override
  String toString() => 'added $added, updated $updated, removed $removed';
}

/// Brings calendars already on a parent's phone into Den (the way around Google and Microsoft
/// sign-ins): the parent picks calendars and who sees each (Everyone, Parents, Just me), and every
/// occurrence from [syncBack] ago to [syncAhead] from now becomes a read-only event with
/// `source: {kind: device, ref: <device>/<calendar>/<event>, label: <calendar name>}`, assigned
/// to the parent. Each pass updates changed events, moves ones whose calendar changed audience,
/// and removes ones deleted on the phone or from a calendar no longer brought in. The picks live
/// on this phone only, for this family; the device id in each ref keeps two phones from ever
/// touching each other's events.
class PhoneCalendars extends ChangeNotifier {
  PhoneCalendars(
    this._den,
    this._source, {
    int Function()? now,
    this.every = const Duration(minutes: 15),
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Shared-preferences key for the picks: `{"family": id, "calendars": {calendarId: audience}}`.
  static const prefKey = 'den.phoneCalendars';

  /// Events that ended this long ago are left as they are.
  static const syncBack = Duration(days: 14);

  /// How far ahead occurrences are brought in; the window rolls forward with every pass.
  static const syncAhead = Duration(days: 180);

  /// Whether this platform has calendars to bring in. Tests turn it on to draw the screen.
  static bool supported =
      Capabilities.phoneCalendars;

  final Den _den;
  final PhoneCalendarSource _source;
  final int Function() _now;

  /// How often a pass runs while the app is open, besides app start and coming back to it.
  final Duration every;

  Map<String, Audience> _picks = {};
  List<PhoneCalendar> _calendars = const [];
  PhoneAccess? _access;
  int? _syncedAt;
  bool _syncing = false;
  Future<PhoneSyncResult>? _running;
  bool _again = false;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  /// Picked calendars and who sees each.
  Map<String, Audience> get picks => Map.unmodifiable(_picks);

  /// The phone's calendars as last listed.
  List<PhoneCalendar> get calendars => _calendars;

  /// Null until asked.
  PhoneAccess? get access => _access;

  /// When the last pass finished (UTC ms).
  int? get syncedAt => _syncedAt;
  bool get syncing => _syncing;

  String get _prefix => '${_den.deviceId}/';

  /// The ref of an occurrence brought in from this phone.
  String refFor(PhoneEvent e) => '$_prefix${e.calendarId}/${e.instanceId}';

  /// Events this phone brought in, by ref.
  Map<String, List<Event>> imported() {
    final out = <String, List<Event>>{};
    for (final e in _den.events) {
      final s = e.source;
      final ref = s.ref;
      if (s.kind != 'device' || ref == null || !ref.startsWith(_prefix)) continue;
      out.putIfAbsent(ref, () => []).add(e);
    }
    return out;
  }

  /// The calendar id inside one of this phone's refs.
  String? calendarOf(String ref) {
    if (!ref.startsWith(_prefix)) return null;
    final rest = ref.substring(_prefix.length);
    final slash = rest.indexOf('/');
    return slash < 0 ? null : rest.substring(0, slash);
  }

  /// How many events this phone holds in Den from [calendarId].
  int countFor(String calendarId) {
    final prefix = '$_prefix$calendarId/';
    return _den.events.where((e) => e.source.kind == 'device' && (e.source.ref?.startsWith(prefix) ?? false)).length;
  }

  /// Loads the picks, runs a pass, and runs one every [every] and whenever the app comes back.
  Future<void> start() async {
    await load();
    _timer = Timer.periodic(every, (_) => unawaited(sync()));
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(sync()));
    await sync();
  }

  /// Reads the picks saved for this family on this phone.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefKey);
      final saved = raw == null ? null : jsonDecode(raw);
      if (saved is Map && saved['family'] == _den.familyId && saved['calendars'] is Map) {
        _picks = {
          for (final e in (saved['calendars'] as Map).entries)
            '${e.key}': ?Audience.values.asNameMap()[e.value],
        };
      } else {
        _picks = {};
      }
    } on Object catch (e) {
      debugPrint('Phone calendar choices could not be read: $e');
    }
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        prefKey,
        jsonEncode({
          'family': _den.familyId,
          'calendars': {for (final e in _picks.entries) e.key: e.value.name},
        }),
      );
    } on Object catch (e) {
      debugPrint('Phone calendar choices could not be saved: $e');
    }
  }

  /// Checks access and lists the phone's calendars, for the screen.
  Future<void> refresh() async {
    try {
      _access = await _source.access();
      _calendars = _access == PhoneAccess.granted ? await _source.calendars() : const [];
    } on Object catch (e) {
      debugPrint('Phone calendars could not be listed: $e');
      _calendars = const [];
    }
    notifyListeners();
  }

  /// Asks for access (the OS dialog), then lists the calendars.
  Future<void> requestAccess() async {
    try {
      _access = await _source.requestAccess();
    } on Object catch (e) {
      debugPrint('Calendar access could not be requested: $e');
    }
    await refresh();
  }

  Future<void> openSettings() => _source.openSettings();

  /// Brings [calendarId] in for [audience], or stops bringing it in (null) and removes its
  /// events, then runs a pass.
  Future<PhoneSyncResult> choose(String calendarId, Audience? audience) async {
    if (audience == null) {
      _picks.remove(calendarId);
    } else {
      _picks[calendarId] = audience;
    }
    notifyListeners();
    await _save();
    return sync();
  }

  /// One pass. Calls during a pass fold into one more.
  Future<PhoneSyncResult> sync() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final run = _loop();
    _running = run;
    return run;
  }

  Future<PhoneSyncResult> _loop() async {
    _syncing = true;
    notifyListeners();
    var total = const PhoneSyncResult();
    try {
      do {
        _again = false;
        final r = await _pass();
        total = PhoneSyncResult(
          added: total.added + r.added,
          updated: total.updated + r.updated,
          removed: total.removed + r.removed,
        );
      } while (_again);
    } on Object catch (e) {
      debugPrint('Phone calendars could not be brought in: $e');
    } finally {
      _running = null;
      _syncing = false;
      notifyListeners();
    }
    return total;
  }

  Future<PhoneSyncResult> _pass() async {
    final me = _den.owner;
    if (!_den.hasFamily || !_den.isApproved || me == null || _den.actor?.id != me.id) return const PhoneSyncResult();
    final held = imported();
    if (_picks.isEmpty && held.isEmpty) return const PhoneSyncResult();

    _access = await _source.access();
    // Without access nothing on the phone can be read, so nothing is removed either.
    if (_access != PhoneAccess.granted) return const PhoneSyncResult();
    _calendars = await _source.calendars();
    final names = {for (final c in _calendars) c.id: c.name};
    final active = [for (final id in _picks.keys) if (names.containsKey(id)) id];

    final now = _now();
    final from = now - syncBack.inMilliseconds;
    final to = now + syncAhead.inMilliseconds;
    final events = active.isEmpty
        ? const <PhoneEvent>[]
        : await _source.events(
            active,
            DateTime.fromMillisecondsSinceEpoch(from),
            DateTime.fromMillisecondsSinceEpoch(to),
          );

    final want = <String, (PhoneEvent, Map<String, Object?>)>{};
    for (final e in events) {
      if (e.cancelled || !active.contains(e.calendarId)) continue;
      final fields = _fields(e, me.id);
      if (fields == null) continue;
      want[refFor(e)] = (e, fields);
    }

    var added = 0, updated = 0, removed = 0;
    for (final entry in held.entries) {
      final ref = entry.key;
      final list = entry.value;
      final calendar = calendarOf(ref);
      final keep = calendar != null && active.contains(calendar);
      for (var i = 0; i < list.length; i++) {
        final e = list[i];
        final inWindow = e.end > from && e.start < to;
        // A duplicate of the same ref, a calendar no longer brought in, or an event gone from
        // the phone inside the window it was read for.
        if (i > 0 || !keep || (!want.containsKey(ref) && inWindow)) {
          await _den.deleteEvent(e.id);
          removed++;
        }
      }
    }

    for (final entry in want.entries) {
      final (phone, fields) = entry.value;
      final audience = _picks[phone.calendarId]!;
      final label = names[phone.calendarId] ?? '';
      final source = {'kind': 'device', 'ref': entry.key, 'label': _cut(label, _maxTitle)};
      final existing = held[entry.key]?.firstOrNull;
      if (existing == null) {
        await _den.addEvent(
          title: fields['title']! as String,
          start: fields['start']! as int,
          end: fields['end']! as int,
          allDay: fields['allDay']! as bool,
          tz: fields['tz']! as String,
          location: fields['location']! as String,
          notes: fields['notes']! as String,
          assignees: [me.id],
          audience: audience,
          source: EventSource('device', entry.key, source['label']),
        );
        added++;
        continue;
      }
      final changes = _changes(existing, {...fields, 'assignees': [me.id], 'source': source});
      final move = existing.space != audience.spaceFor(me.id);
      if (changes.isEmpty && !move) continue;
      await _den.updateEvent(existing.id, {...changes, if (move) 'audience': audience});
      updated++;
    }
    if (active.length != _picks.length) {
      _picks.removeWhere((id, _) => !names.containsKey(id));
      await _save();
    }
    _syncedAt = _now();
    return PhoneSyncResult(added: added, updated: updated, removed: removed);
  }

  /// Den event fields for a phone occurrence; null when it can't be placed on the calendar.
  Map<String, Object?>? _fields(PhoneEvent e, String me) {
    final family = _den.family?.timezone ?? 'UTC';
    final int start;
    final int end;
    if (e.allDay) {
      start = _den.dayStart(_date(e.start));
      final last = _date(e.end);
      end = _den.dayStart(last.compareTo(_date(e.start)) > 0 ? last : _nextDay(e.start));
    } else {
      start = e.start.millisecondsSinceEpoch;
      end = e.end.millisecondsSinceEpoch;
    }
    if (end < start) return null;
    final title = e.title.trim();
    return {
      'title': _cut(title.isEmpty ? 'Busy' : title, _maxTitle),
      'notes': _cut(e.notes, 5000),
      'location': _cut(e.location, 300),
      'start': start,
      'end': end,
      'allDay': e.allDay,
      'tz': e.allDay ? family : _zoneOr(e.timeZone, family),
    };
  }

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _nextDay(DateTime d) => _date(DateTime(d.year, d.month, d.day + 1));

  static String _zoneOr(String? name, String fallback) {
    if (name == null || name.isEmpty) return fallback;
    if (name == 'UTC') return name;
    try {
      tz.getLocation(name);
      return name;
    } on Object {
      return fallback;
    }
  }

  static const _maxTitle = 200;

  static String _cut(String s, int max) => s.length <= max ? s : s.substring(0, max);

  static Map<String, Object?> _changes(Event event, Map<String, Object?> want) {
    final have = event.rec.fields;
    return {
      for (final e in want.entries)
        if (!const DeepCollectionEquality().equals(have[e.key], e.value)) e.key: e.value,
    };
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }
}
