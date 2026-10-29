import 'package:collection/collection.dart';
import 'package:den_capture/den_capture.dart' show CaptureReader;
import 'package:den_core/den_core.dart';
import 'package:den_core/den_core.dart' as core show can;

import 'privacy.dart';
import 'recurrence.dart';
import 'resolve.dart';
import 'runner.dart';
import 'spec.dart';
import 'times.dart';
import 'wire.dart';

/// One call's view of the family: who is acting with what scopes, what they may read, and
/// helpers to find things by name. On the hub the caller is a connection acting as its member
/// (null: a parent-level automation); in the app it's the person using the device.
class ActionContext {
  /// The context for one call on [den], with [member] acting (the engine must already act as
  /// them: `DenGate.run` on the hub). [caller] names who owns receipts and confirmation tokens:
  /// a connection id on the hub, the member's id in the app.
  ActionContext(
    this.den, {
    this.member,
    Set<Scope>? scopes,
    this.surface = Surface.app,
    String? caller,
    Set<String>? readable,
    this.reader,
    this.via,
    String? viewZone,
    this.previewing = false,
  })  : scopes = scopes ?? const {Scope.admin},
        caller = caller ?? member ?? den.deviceId,
        readable = readable ?? readableSpacesFor(den, member),
        viewZone = viewZone == null || viewZone.isEmpty ? null : viewZone,
        wire = Wire(den);

  /// The engine the call reads and writes: the device's own, or a fork for a preview.
  final Den den;

  /// Whose permissions the call uses; null is a parent-level automation on a hub.
  final String? member;

  /// The connection's scopes (`admin` has every one).
  final Set<Scope> scopes;

  /// Where the call came from.
  final Surface surface;

  /// Who owns the receipts and confirmation tokens the call makes.
  final String caller;

  /// Spaces the caller may read.
  final Set<String> readable;

  /// Serializer.
  final Wire wire;

  /// What reads text for `add_from_text`: the hub's reader, or null for Den's own rules.
  final CaptureReader? reader;

  /// The connection's label, as History shows it.
  final String? via;

  /// Where the person the call is for lives, when that isn't the family's zone (a connection's
  /// time zone): answers then say which zone their times and "today" are in, and History shows
  /// its times there. The family's days (when chores are due, which day stars count for) stay
  /// the family's.
  final String? viewZone;

  /// Whether this runs on a fork for a preview: nothing it does may outlast the call.
  final bool previewing;

  /// The zone a read was asked to show times in (its `timezone` argument), or null.
  String? asked;

  /// The zones the answer's times were shown in, for the line that says so.
  final Set<String> shownZones = {};

  /// The runner running the call; set by [ActionRunner.run].
  ActionRunner? runner;

  /// This context over [other] (a fork, for a preview).
  ActionContext on(Den other) => ActionContext(
        other,
        member: member,
        scopes: scopes,
        surface: surface,
        caller: caller,
        readable: readable,
        reader: reader,
        via: via,
        viewZone: viewZone,
        previewing: true,
      )
        ..runner = runner
        ..asked = asked;

  /// Whether the caller's scopes include [scope].
  bool has(Scope scope) => scopes.contains(Scope.admin) || scopes.contains(scope);

  /// The acting member, or null.
  Member? get me => member == null ? null : den.member(member!);

  /// Whether the caller may [action]: the member's permissions. A connection on a hub that acts
  /// for nobody (approved before every connection acted as someone, by a parent no longer in
  /// the family) only reads.
  bool can(DenAction action) {
    final m = me;
    if (m != null) return core.can(m, action);
    final device = den.thisDevice;
    if (member == null && device?.mode == DeviceMode.hub) return false;
    return core.can(null, action, openCheckoff: device?.openCheckoff ?? false);
  }

  /// Who the caller is, for messages: the member's name, or "This connection".
  String get who => me?.name ?? (via == null ? 'This connection' : via!);

  /// The family's zone.
  String get zone => wire.zone;

  /// The zone events' and chores' times are shown in: the one asked for, else the family's.
  String get timesZone => asked ?? zone;

  /// The zone History's times are shown in: the one asked for, else where the person lives,
  /// else the family's.
  String get historyZone => asked ?? viewZone ?? zone;

  /// Whether answers say which zone their times are in: the caller lives in, or asked for,
  /// another zone than the family's.
  bool get labelsZones => (viewZone != null && viewZone != zone) || (asked != null && asked != zone);

  /// The line that says which zone the answer's times are in, or null when nothing needs it.
  String? get zoneLine {
    if (!labelsZones || shownZones.isEmpty) return null;
    return 'Times are ${joinNames([for (final z in shownZones) zoneLabel(z)])} time.';
  }

  /// "3:42 PM" at [millis] in [zoneName] (default [timesZone]), noting the zone for [zoneLine].
  String clockAt(int millis, {String? zoneName}) {
    final z = zoneName ?? timesZone;
    shownZones.add(z);
    return clockText(wallOf(z, millis));
  }

  /// "Fri, Oct 17", with the year when it isn't this year.
  String day(String date) => dayText(date, today);

  /// "Friday, October 17", with the year when it isn't this year.
  String longDay(String date) => longDayText(date, today);

  /// Name resolution for people.
  late final People people = People(den, member);

  /// Today in the family's zone.
  String get today => den.todayDate();

  /// Events the caller may read.
  List<Event> get events => [for (final e in den.events) if (readable.contains(e.space)) e];

  /// Chores the caller may read.
  List<Chore> get chores => [for (final c in den.chores) if (readable.contains(c.space)) c];

  /// Lists the caller may read.
  List<ListState> get lists => [for (final l in den.lists) if (readable.contains(l.list.space)) l];

  /// A list by title or id.
  ListState list(String query) => pick(query, lists, id: (l) => l.list.id, name: (l) => l.list.title, kind: 'list');

  /// A chore by title or id. Several chores of one name ("Make bed" for each kid) are told
  /// apart by whose they are: a person the query names ("Elsie's make bed", "make bed for
  /// Elsie"), else [owner], else the person this call acts for; [date] is the day whose owner
  /// counts (default today). Still more than one is an error listing each with whose it is.
  Chore chore(String query, {String? owner, String? date}) {
    final all = chores;
    final (title, named) = _personIn(query, all.map((c) => c.title));
    final day = date ?? today;
    bool belongs(Chore c, String who) =>
        switch (c.owner) {
          OwnerMember(:final id) => id == who,
          OwnerRotation(:final ids) => ids.contains(who),
          OwnerAnyone() => false,
        } ||
        den.choresOn(day).any((cd) => cd.chore.id == c.id && cd.date == day && cd.owner == who);
    return pick(
      title,
      all,
      id: (c) => c.id,
      name: (c) => c.title,
      kind: 'chore',
      describe: (c) => '${c.title} (${ownerText(c)}, id ${c.id})',
      narrow: [
        for (final who in [?named, ?owner, ?member]) (found) => [for (final c in found) if (belongs(c, who)) c],
      ],
    );
  }

  /// [query] as a title and the person it names, when it names one the way people do ("Elsie's
  /// make bed", "make bed for Elsie", "make bed (Elsie)") and what's left is one of [titles].
  (String, String?) _personIn(String query, Iterable<String> titles) {
    final q = query.trim();
    final known = {for (final t in titles) _norm(t)};
    if (known.contains(_norm(q))) return (q, null);
    final tries = <(String, String)>[
      if (RegExp(r"^(.+?)['’]s\s+(.+)$").firstMatch(q) case final m?) (m[1]!, m[2]!),
      if (RegExp(r'^(.+)\s+for\s+(.+)$', caseSensitive: false).firstMatch(q) case final m?) (m[2]!, m[1]!),
      if (RegExp(r'^(.+?)\s*\((.+)\)$').firstMatch(q) case final m?) (m[2]!, m[1]!),
    ];
    for (final (name, rest) in tries) {
      final who = [
        for (final x in den.members)
          if (_norm(x.name) == _norm(name) || _norm(x.name.split(' ').first) == _norm(name)) x,
      ];
      if (who.length == 1 && known.contains(_norm(rest))) return (rest.trim(), who.single.id);
    }
    return (q, null);
  }

  /// Who a chore belongs to, in words.
  String ownerText(Chore c) => switch (c.owner) {
        OwnerMember(:final id) => people.name(id),
        OwnerAnyone() => 'anyone',
        final OwnerRotation r => 'rotating ${people.names(r.ids)}',
      };

  static String _norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// An event by title or id. Several of one name are told apart by [at] (a date or time the
  /// caller named: the event that has an occurrence then), then, for one activity whose repeat
  /// was split ("this and following" makes a new event of the same name, starting where the
  /// first one ends), by which is still to come, then by a person the query names ("Jimmy's
  /// soccer"), then by the person this call acts for.
  Event event(String query, {Object? at}) {
    final all = events;
    final (title, named) = _personIn(query, all.map((e) => e.title));
    return pick(
      title,
      all,
      id: (e) => e.id,
      name: (e) => e.title,
      kind: 'event',
      describe: (e) => '${e.title} (${_eventSpan(e)}${e.assignees.isEmpty ? '' : ', for ${people.names(e.assignees)}'}, id ${e.id})',
      narrow: [
        if (at != null) (found) => _happeningAt(found, at),
        _stillToCome,
        for (final who in [?named, ?member]) (found) => [for (final e in found) if (e.assignees.contains(who)) e],
      ],
    );
  }

  /// "Tue, Oct 27" for a single event; "repeating from Tue, Oct 27" for a series that goes on,
  /// "repeating Tue, Oct 27 to Tue, Nov 3" for one that ends.
  String _eventSpan(Event e) {
    final first = day(dateIn(zone, e.start));
    if (e.rrule == null) return first;
    final horizon = den.now() + 400 * Duration.millisecondsPerDay;
    int? last;
    for (final s in seriesStartsOf(e, zone, notBefore: e.start)) {
      if (s > horizon) return 'repeating from $first';
      last = s;
    }
    return last == null || last == e.start ? first : 'repeating $first to ${day(dateIn(zone, last))}';
  }

  /// The events of [found] that have an occurrence at [value]: on that day for a date, starting
  /// then for a time.
  List<Event> _happeningAt(List<Event> found, Object value) {
    final text = '$value'.trim();
    final ids = {for (final e in found) e.id};
    final dayOf = isDate(text) ? text : relativeDate(text, today, weekStart: weekStart);
    int from, to;
    int? exact;
    if (dayOf != null) {
      from = midnightIn(zone, dayOf);
      to = midnightIn(zone, addDays(dayOf, 1));
    } else {
      try {
        exact = int.tryParse(text) ?? instant(value, 'occurrence');
      } on ActionError {
        return const [];
      }
      from = exact - Duration.millisecondsPerDay;
      to = exact + Duration.millisecondsPerDay;
    }
    final hit = <String>{};
    for (final o in den.occurrences(from, to)) {
      if (!ids.contains(o.event.id)) continue;
      if (exact == null || o.start == exact || Wire.occurrenceKey(o) == exact) hit.add(o.event.id);
    }
    return [for (final e in found) if (hit.contains(e.id)) e];
  }

  /// For events of one name that follow one another (each ends before the next begins, as a
  /// split repeat does): the one still to come, else the last. Events of one name that run at
  /// the same time are different things, and this keeps them all.
  List<Event> _stillToCome(List<Event> found) {
    if (found.length < 2 || found.map((e) => _norm(e.title)).toSet().length != 1) return found;
    final ordered = [...found]..sort((a, b) => a.start.compareTo(b.start));
    for (var i = 0; i + 1 < ordered.length; i++) {
      if (seriesStartsOf(ordered[i], zone, notBefore: ordered[i + 1].start).isNotEmpty) return found;
    }
    final now = den.now() - 6 * Duration.millisecondsPerHour;
    for (final e in ordered) {
      if (seriesStartsOf(e, zone, notBefore: now).isNotEmpty) return [e];
    }
    return [ordered.last];
  }

  /// A category by name or id.
  String category(String query) => pick(query, den.categories, id: (c) => c.id, name: (c) => c.name, kind: 'category').id;

  /// A reward that can be asked for, by title or id. One that was retired says so.
  Reward reward(String query) {
    try {
      return pick(query, den.points().rewards, id: (r) => r.id, name: (r) => r.title, kind: 'reward');
    } on ActionError {
      final retired = den.rewards.where((r) => !r.active && (r.id == query.trim() || _norm(r.title) == _norm(query))).firstOrNull;
      if (retired != null) {
        throw ActionError.notFound(
          '${retired.title} was retired, so nobody can ask for it; a parent can bring it back (save_reward with "active": true).',
          type: 'reward',
          id: retired.id,
        );
      }
      rethrow;
    }
  }

  /// The family's first day of the week (0 Sunday, 1 Monday).
  int get weekStart => den.family?.weekStart ?? 0;

  /// A date input: a date, the date of a time, or words such as "tomorrow" or "next Friday".
  String date(Object? value, String field) => toolDate(value, zone, field, today: today, weekStart: weekStart);

  /// A time input in [zoneName] (default the family's): ISO 8601, a date, or words such as
  /// "next Friday 3pm". A wall-clock time the clocks skip or repeat is told to [note].
  int instant(Object? value, String field, {String? zoneName, void Function(String)? note}) =>
      toolInstant(value, zoneName ?? zone, field, today: today, weekStart: weekStart, note: note);

  /// The space for a "who can see it" input: everyone, parents, just me, or a person's name.
  String space(Object? value) {
    if (value == null) return Space.family;
    final v = '$value'.trim().toLowerCase();
    String space;
    if (v == 'everyone' || v == 'family' || v == 'f') {
      space = Space.family;
    } else if (v == 'parents' || v == 'p') {
      space = Space.parents;
    } else if (v == 'just me' || v == 'me' || v == 'private') {
      final me = member;
      if (me == null) throw ActionError('This connection doesn\'t belong to one person; name whose private item it is.');
      space = Space.member(me);
    } else if (v.startsWith('m:')) {
      space = Space.member(people.one('$value'.trim().substring(2)));
    } else {
      space = Space.member(people.one('$value'));
    }
    if (!readable.contains(space)) throw ActionError.denied('This connection can\'t see that, so it can\'t put things there.');
    return space;
  }

  /// "Tue, Oct 20, 5:30 PM–6:30 PM", in [timesZone], with the year when it isn't this year. Two
  /// clock times that read the same (an hour from 1:30 AM the night the clocks fall back) say
  /// which is which: "1:30 AM EDT–1:30 AM EST".
  String when(Occurrence o) {
    final z = timesZone;
    final date = dateIn(z, o.start);
    if (o.allDay) {
      final last = addDays(dateIn(z, o.end), -1);
      return last.compareTo(date) > 0 ? '${day(date)} to ${day(last)}, all day' : '${day(date)}, all day';
    }
    var start = clockAt(o.start);
    if (o.end <= o.start) return '${day(date)}, $start';
    var end = clockAt(o.end);
    if (start == end) {
      start = '$start ${zoneAbbreviation(z, o.start)}';
      end = '$end ${zoneAbbreviation(z, o.end)}';
    }
    final endDate = dateIn(z, o.end);
    return '${day(date)}, $start–${endDate == date ? '' : '${day(endDate)}, '}$end';
  }

  /// Who can see a record in [space], for a line about it: nothing for everyone, "parents only",
  /// or "only Maya".
  String audienceText(String space) {
    if (space == Space.family) return '';
    if (space == Space.parents) return 'parents only';
    return 'only ${people.name(Space.memberOf(space))}';
  }

  /// One line for an occurrence: when, what, who it's for and who can see it, where.
  String occurrenceLine(Occurrence o) {
    final who = o.assignees.isEmpty ? 'for everyone' : 'for ${people.names(o.assignees)}';
    final seen = audienceText(o.event.space);
    final at = o.location.isEmpty ? '' : ' at ${o.location}';
    return '- ${when(o)}: ${o.title} ($who${seen.isEmpty ? '' : '; $seen'})$at '
        '[event ${o.event.id}${o.isRepeating ? ', occurrence ${Wire.occurrenceKey(o)}' : ''}]';
  }

  /// One line for a chore on a day.
  String choreLine(ChoreDay cd) {
    final who = cd.owner == null ? 'anyone' : people.name(cd.owner);
    final state = cd.done
        ? 'done${cd.doneBy == null ? '' : ' by ${people.name(cd.doneBy)}'}'
        : cd.late
            ? 'late'
            : 'not done';
    final dueAt = cd.chore.dueTime == null
        ? null
        : utcOfWall(zone, wallOfDate(cd.date).add(Duration(minutes: _minutes(cd.chore.dueTime!))));
    final due = dueAt == null ? '' : ', due ${clockAt(dueAt)}';
    final steps = cd.stepCount == 0 ? '' : ', ${cd.stepsDone} of ${cd.stepCount} steps';
    final points = cd.pointsAvailable == 0 ? '' : ', ${stars(cd.pointsAvailable)}';
    final when = cd.date == today ? '' : ' (${day(cd.date)})';
    final seen = audienceText(cd.chore.space);
    return '- ${cd.chore.title}$when for $who${seen.isEmpty ? '' : ' ($seen)'}: $state$due$steps$points [chore ${cd.chore.id}]';
  }

  static int _minutes(String hhmm) => int.parse(hhmm.substring(0, 2)) * 60 + int.parse(hhmm.substring(3));

  /// Chores on [date] the caller may read, in display order.
  List<ChoreDay> choresOn(String date) {
    final list = [for (final cd in den.choresOn(date)) if (readable.contains(cd.chore.space)) cd];
    Wire.sortChores(list);
    return list;
  }

  /// Occurrences in [start, end) the caller may read, in order.
  List<Occurrence> occurrences(int start, int end) {
    final list = [for (final o in den.occurrences(start, end)) if (readable.contains(o.event.space)) o];
    Wire.sortOccurrences(list);
    return list;
  }

  /// Finds an item by text or id, in [list] when given.
  (ListState, Item) item(String query, {ListState? list}) {
    final pool = [
      for (final l in list == null ? lists : [list])
        for (final i in l.items) (l, i),
    ];
    return pick(
      query,
      pool,
      id: (p) => p.$2.id,
      name: (p) => p.$2.text,
      kind: 'item',
      describe: (p) => '${p.$2.text} on ${p.$1.list.title} (id ${p.$2.id})',
    );
  }

  /// The occurrence of [event] on or at [value] (a time, a date, or words such as "Tuesday"), as
  /// its original start. One that was removed from the series says so.
  int occurrenceOf(Event event, Object? value) {
    final text = '$value'.trim();
    final exact = int.tryParse(text);
    final dayOf = isDate(text) ? text : relativeDate(text, today, weekStart: weekStart);
    final starts = <int, Occurrence>{};
    final at = exact ?? (dayOf != null ? midnightIn(zone, dayOf) : instant(value, 'occurrence'));
    for (final o in den.occurrences(at - 2 * Duration.millisecondsPerDay, at + 2 * Duration.millisecondsPerDay)) {
      if (o.event.id == event.id) starts[Wire.occurrenceKey(o)] = o;
    }
    if (exact != null && starts.containsKey(exact)) return exact;
    if (dayOf != null) {
      final onDay = starts.entries.where((e) => dateIn(zone, e.value.start) == dayOf).toList();
      if (onDay.length == 1) return onDay.single.key;
    } else {
      final match = starts.entries.firstWhereOrNull((e) => e.key == at || e.value.start == at);
      if (match != null) return match.key;
    }
    if (exact != null && isOccurrenceOf(event, zone, exact)) return exact;
    // A start the series has that the calendar doesn't show was removed on its own.
    final from = dayOf != null ? midnightIn(zone, dayOf) : at;
    final to = dayOf != null ? midnightIn(zone, addDays(dayOf, 1)) : at + 1;
    for (final s in seriesStartsOf(event, zone, notBefore: from)) {
      if (s >= to) break;
      if (!starts.containsKey(s)) {
        throw ActionError.notFound('${event.title} on ${day(dateIn(zone, s))} was cancelled, so it can\'t change. Undo with '
            '"type": "event", "id": "${event.id}" and that "occurrence" puts it back.', type: 'event', id: event.id);
      }
    }
    final near = starts.values.map(when).join('; ');
    final asked = dayOf != null ? longDay(dayOf) : '"$value"';
    throw ActionError('${event.title} doesn\'t happen ${dayOf != null ? 'on' : 'at'} $asked.${near.isEmpty ? '' : ' Nearby: $near.'}',
        field: 'occurrence');
  }
}
