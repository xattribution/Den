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
  })  : scopes = scopes ?? const {Scope.admin},
        caller = caller ?? member ?? den.deviceId,
        readable = readable ?? readableSpacesFor(den, member),
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
      )..runner = runner;

  /// Whether the caller's scopes include [scope].
  bool has(Scope scope) => scopes.contains(Scope.admin) || scopes.contains(scope);

  /// The acting member, or null.
  Member? get me => member == null ? null : den.member(member!);

  /// Whether the caller may [action]: the member's permissions, or for a hub automation with no
  /// member, a parent's except family administration (as the engine decides).
  bool can(DenAction action) {
    final m = me;
    if (m != null) return core.can(m, action);
    final device = den.thisDevice;
    if (member == null && device?.mode == DeviceMode.hub) return action != DenAction.manageFamily;
    return core.can(null, action, openCheckoff: device?.openCheckoff ?? false);
  }

  /// Who the caller is, for messages: the member's name, or "This connection".
  String get who => me?.name ?? (via == null ? 'This connection' : via!);

  /// The family's zone.
  String get zone => wire.zone;

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

  /// A chore by title or id; [owner] narrows chores that share a title.
  Chore chore(String query, {String? owner, String? date}) {
    final all = chores;
    if (owner != null) {
      final day = date ?? today;
      final owned = [
        for (final c in all)
          if (_norm(c.title) == _norm(query) && den.choresOn(day).any((cd) => cd.chore.id == c.id && cd.owner == owner)) c,
      ];
      if (owned.length == 1) return owned.single;
    }
    return pick(
      query,
      all,
      id: (c) => c.id,
      name: (c) => c.title,
      kind: 'chore',
      describe: (c) => '${c.title} (${ownerText(c)}, id ${c.id})',
    );
  }

  /// Who a chore belongs to, in words.
  String ownerText(Chore c) => switch (c.owner) {
        OwnerMember(:final id) => people.name(id),
        OwnerAnyone() => 'anyone',
        final OwnerRotation r => 'rotating ${people.names(r.ids)}',
      };

  static String _norm(String s) => s.trim().toLowerCase();

  /// An event by title or id.
  Event event(String query) => pick(
        query,
        events,
        id: (e) => e.id,
        name: (e) => e.title,
        kind: 'event',
        describe: (e) => '${e.title} (${shortDate(dateIn(zone, e.start))}, id ${e.id})',
      );

  /// A category by name or id.
  String category(String query) => pick(query, den.categories, id: (c) => c.id, name: (c) => c.name, kind: 'category').id;

  /// A reward by title or id.
  Reward reward(String query) => pick(query, den.points().rewards, id: (r) => r.id, name: (r) => r.title, kind: 'reward');

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

  /// "Tue, Oct 20, 5:30 PM–6:30 PM".
  String when(Occurrence o) {
    final date = dateIn(zone, o.start);
    if (o.allDay) {
      final last = addDays(dateIn(zone, o.end), -1);
      return last.compareTo(date) > 0 ? '${shortDate(date)} to ${shortDate(last)}, all day' : '${shortDate(date)}, all day';
    }
    final start = clockText(wallOf(zone, o.start));
    if (o.end <= o.start) return '${shortDate(date)}, $start';
    return '${shortDate(date)}, $start–${clockText(wallOf(zone, o.end))}';
  }

  /// One line for an occurrence.
  String occurrenceLine(Occurrence o) {
    final who = o.assignees.isEmpty ? 'everyone' : people.names(o.assignees);
    final at = o.location.isEmpty ? '' : ' at ${o.location}';
    return '- ${when(o)}: ${o.title} ($who)$at [event ${o.event.id}${o.isRepeating ? ', occurrence ${Wire.occurrenceKey(o)}' : ''}]';
  }

  /// One line for a chore on a day.
  String choreLine(ChoreDay cd) {
    final who = cd.owner == null ? 'anyone' : people.name(cd.owner);
    final state = cd.done
        ? 'done${cd.doneBy == null ? '' : ' by ${people.name(cd.doneBy)}'}'
        : cd.late
            ? 'late'
            : 'not done';
    final due = cd.chore.dueTime == null ? '' : ', due ${clockText(wallOfDate(cd.date).add(Duration(minutes: _minutes(cd.chore.dueTime!))))}';
    final steps = cd.stepCount == 0 ? '' : ', ${cd.stepsDone} of ${cd.stepCount} steps';
    final points = cd.pointsAvailable == 0 ? '' : ', ${cd.pointsAvailable} stars';
    final day = cd.date == today ? '' : ' (${shortDate(cd.date)})';
    return '- ${cd.chore.title}$day for $who: $state$due$steps$points [chore ${cd.chore.id}]';
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

  /// The occurrence of [event] on or at [value] (a time or a date), as its original start.
  int occurrenceOf(Event event, Object? value) {
    final text = '$value'.trim();
    final exact = int.tryParse(text);
    final starts = <int, Occurrence>{};
    final from = exact ?? toolInstant(value, zone, 'occurrence');
    for (final o in den.occurrences(from - 2 * Duration.millisecondsPerDay, from + 2 * Duration.millisecondsPerDay)) {
      if (o.event.id == event.id) starts[Wire.occurrenceKey(o)] = o;
    }
    if (exact != null && starts.containsKey(exact)) return exact;
    final at = toolInstant(value, zone, 'occurrence');
    final match = starts.entries.firstWhereOrNull((e) => e.key == at || e.value.start == at);
    if (match != null) return match.key;
    if (isDate(text)) {
      final onDay = starts.entries.where((e) => dateIn(zone, e.value.start) == text).toList();
      if (onDay.length == 1) return onDay.single.key;
    }
    if (exact != null && isOccurrenceOf(event, zone, exact)) return exact;
    final near = starts.values.map(when).join('; ');
    throw ActionError('${event.title} doesn\'t happen at "$value".${near.isEmpty ? '' : ' Nearby: $near.'}', field: 'occurrence');
  }
}
