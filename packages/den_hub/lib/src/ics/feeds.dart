import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';

import '../context.dart';
import '../hub.dart';
import '../log.dart';
import '../times.dart';
import 'expand.dart';
import 'fetch.dart';
import 'import.dart';
import 'parse.dart';

/// Calendar feeds in: fetches every `subscription` record's ICS feed on a schedule and when the
/// subscription changes, and keeps the hub-written events in its target space in step.
class FeedService implements HubService {
  /// Creates the service for [hub].
  FeedService(this.hub);

  /// Shared hub context.
  final HubContext hub;

  @override
  String get name => 'Calendar feeds';

  Timer? _timer;
  StreamSubscription<Set<String>>? _changes;
  Timer? _soon;
  Future<void> _running = Future.value();

  Map<String, Object?> get _doc => hub.state.read('feeds');

  Map<String, Object?> _entry(String id) {
    final raw = _doc[id];
    if (raw is Map<String, Object?>) return raw;
    final fresh = <String, Object?>{...?(raw as Map?)?.cast<String, Object?>()};
    _doc[id] = fresh;
    return fresh;
  }

  @override
  Future<void> start() async {
    _timer = Timer.periodic(hub.config.feedInterval, (_) => unawaited(syncAll()));
    _changes = hub.den.onChange.listen((types) {
      if (types.contains(RecordType.subscription)) {
        _soon?.cancel();
        _soon = Timer(const Duration(seconds: 1), () => unawaited(syncAll(onlyChanged: true)));
      }
    });
    unawaited(syncAll());
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _soon?.cancel();
    await _changes?.cancel();
    await _running;
  }

  static String _fingerprint(Subscription s) => jsonEncode([
        s.url, s.label, s.category, s.assignee, s.targetSpace, s.include, s.exclude, s.skipAllDay,
      ]);

  /// Fetches every feed (or, with [onlyChanged], the new and changed ones) one at a time.
  Future<void> syncAll({bool onlyChanged = false}) {
    final run = _running.then((_) async {
      final subs = await hub.gate.asHub(() => hub.den.subscriptions);
      final ids = {for (final s in subs) s.id};
      for (final gone in _doc.keys.where((k) => !ids.contains(k)).toList()) {
        await _removeAll(gone);
      }
      for (final s in subs) {
        if (onlyChanged && _entry(s.id)['config'] == _fingerprint(s)) continue;
        try {
          await syncOne(s);
        } on Object catch (e, st) {
          hub.log.error('Calendar feed sync failed: ${describeError(e, st)}');
        }
      }
      await hub.state.save('feeds');
    });
    _running = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _removeAll(String subscription) async {
    final events = ((_entry(subscription)['events'] as Map?) ?? const {}).values.whereType<String>();
    for (final id in events) {
      await hub.gate.asHub(() async {
        if (hub.den.event(id) != null) await hub.den.deleteEvent(id);
      }, via: 'Calendar feed');
    }
    _doc.remove(subscription);
  }

  Future<void> _status(Subscription s, String status) async {
    final entry = _entry(s.id);
    if (entry['status'] == status) return;
    entry['status'] = status;
    await hub.gate.asHub(() async {
      if (hub.den.subscription(s.id) != null) await hub.den.setSubscriptionStatus(s.id, status.length > 500 ? status.substring(0, 500) : status);
    });
  }

  /// Fetches one feed and applies it. Returns how many series it holds, or null when it failed.
  Future<int?> syncOne(Subscription s) async {
    final entry = _entry(s.id);
    final fingerprint = _fingerprint(s);
    final changedConfig = entry['config'] != fingerprint;
    final fetched = await fetchFeed(
      hub.http,
      s.url,
      etag: changedConfig ? null : entry['etag'] as String?,
      modified: changedConfig ? null : entry['modified'] as String?,
    );
    if (fetched.problem != null) {
      hub.log.warn('A calendar feed failed: ${fetched.temporary ? 'temporarily' : 'link broken'}');
      await _status(s, fetched.problem!);
      return null;
    }
    if (fetched.notModified && !changedConfig) return (entry['events'] as Map?)?.length ?? 0;
    final text = fetched.text!;
    final hash = hashToken(text);
    if (!changedConfig && entry['hash'] == hash) return (entry['events'] as Map?)?.length ?? 0;
    final IcsCalendar calendar;
    try {
      calendar = parseIcs(text, defaultZone: hub.zone);
    } on IcsFormatException {
      await _status(s, 'That link isn\'t a calendar file.');
      return null;
    }
    final label = s.label.isNotEmpty ? s.label : (calendar.name ?? 'Calendar');
    final count = await _apply(s, calendar, label);
    entry
      ..['config'] = fingerprint
      ..['etag'] = fetched.etag
      ..['modified'] = fetched.modified
      ..['hash'] = hash;
    final wall = wallOf(hub.zone, hub.now());
    await _status(s, '$count event${count == 1 ? '' : 's'}, updated ${clockText(wall)}');
    hub.log.info('A calendar feed was updated');
    return count;
  }

  Future<int> _apply(Subscription s, IcsCalendar calendar, String label) async {
    final entry = _entry(s.id);
    final mapped = <String, String>{...?(entry['events'] as Map?)?.cast<String, String>()};
    final plan = planFeed(calendar, s, now: hub.now(), label: label);
    final via = label;
    for (final uid in plan.fields.keys) {
      final want = plan.fields[uid]!;
      final id = await hub.gate.asHub(() async {
        final existing = mapped[uid] == null ? null : hub.den.event(mapped[uid]!);
        if (existing != null && existing.space == s.targetSpace) {
          final changes = eventChanges(existing, want);
          if (changes.isNotEmpty) await hub.den.updateEvent(existing.id, changes);
          return existing.id;
        }
        if (existing != null) await hub.den.deleteEvent(existing.id);
        final source = want['source'] as Map<String, Object?>;
        return hub.den.addEvent(
          title: want['title'] as String,
          start: want['start'] as int,
          end: want['end'] as int,
          allDay: want['allDay'] as bool,
          tz: want['tz'] as String,
          rrule: want['rrule'] as String?,
          assignees: (want['assignees'] as List).cast<String>(),
          category: want['category'] as String?,
          location: want['location'] as String,
          notes: want['notes'] as String,
          space: s.targetSpace,
          source: EventSource('ics', source['ref'] as String?, source['label'] as String?),
        );
      }, via: via);
      mapped[uid] = id;
      final series = plan.series[uid]!;
      if (series.rule != null) await _exceptions(id, series, s.targetSpace, via);
    }
    for (final uid in mapped.keys.where((u) => !plan.fields.containsKey(u)).toList()) {
      final id = mapped.remove(uid)!;
      await hub.gate.asHub(() async {
        if (hub.den.event(id) != null) await hub.den.deleteEvent(id);
      }, via: via);
    }
    entry['events'] = mapped;
    return mapped.length;
  }

  Future<void> _exceptions(String id, IcsSeries series, String space, String via) => hub.gate.asHub(() async {
        final event = hub.den.event(id);
        if (event == null) return;
        final wanted = wantedExceptions(series, event, hub.zone);
        final held = heldExceptions(hub.den, id, space);
        for (final occurrence in wanted.cancel) {
          if (held[occurrence]?.cancelled != true) {
            await hub.den.deleteEvent(id, scope: EditScope.one, occurrence: occurrence);
          }
        }
        for (final e in wanted.patch.entries) {
          final have = held[e.key];
          final clear = {for (final k in have?.patch.keys ?? const <String>[]) if (!e.value.containsKey(k)) k: null};
          final same = have != null && !have.cancelled && clear.isEmpty && const DeepCollectionEquality().equals(have.patch, e.value);
          if (!same) await hub.den.updateEvent(id, {...clear, ...e.value}, scope: EditScope.one, occurrence: e.key);
        }
        for (final e in held.entries) {
          if (wanted.cancel.contains(e.key) || wanted.patch.containsKey(e.key)) continue;
          if (!e.value.cancelled && e.value.patch.isEmpty) continue;
          final reset = {for (final k in e.value.patch.keys) k: null};
          await hub.den.updateEvent(id, reset.isEmpty ? {'title': null} : reset, scope: EditScope.one, occurrence: e.key);
        }
      }, via: via);
}
