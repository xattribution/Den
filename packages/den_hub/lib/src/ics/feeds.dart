import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:den_actions/times.dart';
import 'package:den_core/den_core.dart';

import '../context.dart';
import '../hub.dart';
import '../log.dart';
import 'expand.dart';
import 'fetch.dart';
import 'import.dart';
import 'parse.dart';
import 'watch.dart';
import 'write.dart';

/// How often a Den share (another family's shared calendar) is fetched even when its watch
/// stream is quiet: the fallback for a stream that can't stay open.
const Duration sharePoll = Duration(minutes: 15);

/// "The Kotvas family", "The Carter family" or "The Riveras", for a family named [name] ("Kotvas",
/// "Carter family", "The Riveras").
String familyPhrase(String? name) {
  final n = name?.trim() ?? '';
  if (n.isEmpty) return 'The other family';
  final lower = n.toLowerCase();
  if (lower.startsWith('the ')) return 'The ${n.substring(4)}';
  if (lower.endsWith(' family')) return 'The $n';
  return 'The $n family';
}

/// Calendar feeds in: fetches every `subscription` record's ICS feed on a schedule and when the
/// subscription changes, and keeps the hub-written events in its target space in step.
///
/// Crash-safe: which event each feed UID became is saved as the sync goes (every
/// [saveEvery] new events, and after each feed), and a sync that starts over finds the events a
/// cut-short one wrote by the UID they carry (`source.ref`), so it updates them instead of
/// adding copies, and removes copies an earlier version of the hub left behind.
///
/// Every feed leaves out the family's own events coming back (UIDs `@<familyId>.den`). A Den
/// share, another family's shared feed ([shareWatchUri]), also gets a watch stream
/// ([ShareWatcher]): its hub says when its Everyone events change and this hub fetches it at once,
/// with a fetch every [sharePoll] as the fallback. When that family stops sharing (the stream
/// says `revoked`, or the feed answers `401`), every event copied from it goes and the
/// subscription's status says so.
class FeedService implements HubService {
  /// Creates the service for [hub].
  FeedService(this.hub);

  /// Shared hub context.
  final HubContext hub;

  /// New imported events after which the hub saves which UID became which event.
  static const int saveEvery = 25;

  /// How long [stop] waits for a sync in progress to reach a point where it can stop.
  static const Duration stopWait = Duration(seconds: 5);

  @override
  String get name => 'Calendar feeds';

  Timer? _timer;
  Timer? _sharesTimer;
  StreamSubscription<Set<String>>? _changes;
  Timer? _soon;
  Future<void> _running = Future.value();
  bool _stopping = false;
  final Map<String, ({String url, ShareWatcher watcher})> _watches = {};
  final Set<String> _due = {};

  /// The subscriptions whose share's watch stream is open now.
  Set<String> get watching => {
        for (final e in _watches.entries)
          if (e.value.watcher.connected) e.key,
      };

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
    _stopping = false;
    _timer = Timer.periodic(hub.config.feedInterval, (_) => unawaited(syncAll()));
    _sharesTimer = Timer.periodic(sharePoll, (_) => unawaited(_syncWhere((s) => shareWatchUri(s.url) != null)));
    _changes = hub.den.onChange.listen((types) {
      if (types.contains(RecordType.subscription)) {
        _soon?.cancel();
        _soon = Timer(const Duration(seconds: 1), () => unawaited(syncAll(onlyChanged: true)));
      }
    });
    unawaited(syncAll());
  }

  /// Stops fetching. A sync in progress stops at its next event (what it did so far is saved);
  /// this waits at most [stopWait] for it, so a slow calendar server never holds up the hub.
  @override
  Future<void> stop() async {
    _stopping = true;
    _timer?.cancel();
    _sharesTimer?.cancel();
    _soon?.cancel();
    await _changes?.cancel();
    final watches = [for (final w in _watches.values) w.watcher];
    _watches.clear();
    await Future.wait([for (final w in watches) w.stop()]);
    await _running.timeout(stopWait, onTimeout: () {});
    await hub.state.save('feeds');
  }

  static String _fingerprint(Subscription s) => jsonEncode([
        s.url, s.label, s.category, s.assignee, s.targetSpace, s.include, s.exclude, s.skipAllDay,
      ]);

  /// Runs [body] after whatever sync is running: one at a time.
  Future<void> _queue(Future<void> Function() body) {
    final run = _running.then((_) => body());
    _running = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  /// Fetches every feed (or, with [onlyChanged], the new and changed ones) one at a time. Does
  /// nothing while the hub is catching up after a restore ([HubContext.catchingUp]).
  Future<void> syncAll({bool onlyChanged = false}) => _queue(() async {
        if (_stopping || hub.catchingUp) return;
        final subs = await hub.gate.asHub(() => hub.den.subscriptions);
        final ids = {for (final s in subs) s.id};
        for (final gone in _doc.keys.where((k) => !ids.contains(k)).toList()) {
          if (_stopping) return;
          await _removeAll(gone);
          await hub.state.save('feeds');
        }
        for (final s in subs) {
          if (_stopping) return;
          if (onlyChanged && _entry(s.id)['config'] == _fingerprint(s)) continue;
          await _syncGuarded(s);
        }
        _watchShares(subs);
      });

  /// Fetches the feeds [which] picks, one at a time.
  Future<void> _syncWhere(bool Function(Subscription s) which) => _queue(() async {
        if (_stopping || hub.catchingUp) return;
        final subs = await hub.gate.asHub(() => hub.den.subscriptions);
        for (final s in subs) {
          if (_stopping) return;
          if (which(s)) await _syncGuarded(s);
        }
      });

  Future<void> _syncGuarded(Subscription s) async {
    try {
      await syncOne(s);
    } on Object catch (e, st) {
      hub.log.error('Calendar feed sync failed: ${describeError(e, st)}');
      await _status(s, 'Den couldn\'t update this calendar. It will try again.');
    } finally {
      await hub.state.save('feeds');
    }
  }

  /// Fetches subscription [id] soon: its share said it changed. Calls while a fetch waits join
  /// it.
  void _wake(String id) {
    if (_stopping) return;
    final first = _due.isEmpty;
    _due.add(id);
    if (!first) return;
    unawaited(_queue(() async {
      final ids = {..._due};
      _due.clear();
      if (_stopping || hub.catchingUp) return;
      final subs = await hub.gate.asHub(() => hub.den.subscriptions);
      for (final s in subs) {
        if (_stopping) return;
        if (ids.contains(s.id)) await _syncGuarded(s);
      }
    }));
  }

  /// Keeps a watch stream open for each Den share in [subs] that is still shared, and closes
  /// the others.
  void _watchShares(List<Subscription> subs) {
    if (_stopping) return;
    final want = <String, Subscription>{
      for (final s in subs)
        if (shareWatchUri(s.url) != null && _entry(s.id)['stopped'] != true) s.id: s,
    };
    for (final id in _watches.keys.toList()) {
      if (want[id]?.url == _watches[id]!.url) continue;
      unawaited(_watches.remove(id)!.watcher.stop());
    }
    for (final s in want.values) {
      if (_watches.containsKey(s.id)) continue;
      final id = s.id;
      void maybe(String? etag) {
        if (etag == null || etag != _entry(id)['etag']) _wake(id);
      }

      final watcher = ShareWatcher(
        client: hub.feedFetch,
        uri: shareWatchUri(s.url)!,
        log: hub.log,
        onHello: maybe,
        onChanged: maybe,
        onRevoked: () {
          _watches.remove(id);
          unawaited(_queue(() async {
            if (_stopping) return;
            final sub = await hub.gate.asHub(() => hub.den.subscription(id));
            if (sub == null) return;
            await _stoppedSharing(sub);
            await hub.state.save('feeds');
          }));
        },
      );
      _watches[id] = (url: s.url, watcher: watcher);
      watcher.start();
    }
  }

  /// The family behind Den share [s] stopped sharing (they turned the link off): every event
  /// copied from it goes, and the subscription's status says so. Only for Den shares; another
  /// calendar that stops working keeps what it had and says the link doesn't work.
  Future<void> _stoppedSharing(Subscription s) async {
    final entry = _entry(s.id);
    final already = entry['stopped'] == true;
    final from = entry['from'] as String? ?? (s.label.isEmpty ? null : s.label);
    final family = entry['family'] as String?;
    final ids = <String>{...?((entry['events'] as Map?)?.values.whereType<String>())};
    if (family != null) {
      // Copies a cut-short sync wrote before it saved them: the sharing family's UIDs, in this
      // feed's space, that no other feed holds.
      final claimed = <String>{
        for (final e in _doc.entries)
          if (e.key != s.id && e.value is Map)
            ...(((e.value as Map)['events'] as Map?)?.values.whereType<String>() ?? const <String>[]),
      };
      final suffix = '@${sharedUidDomain(family)}';
      await hub.gate.asHub<void>(() {
        for (final e in hub.den.events) {
          if (e.space == s.targetSpace &&
              e.source.kind == 'ics' &&
              !claimed.contains(e.id) &&
              (e.source.ref?.endsWith(suffix) ?? false)) {
            ids.add(e.id);
          }
        }
      });
    }
    final via = s.label.isNotEmpty ? s.label : (from ?? 'Calendar feed');
    for (final id in ids) {
      await hub.gate.asHub(() async {
        if (hub.den.event(id) != null) await hub.den.deleteEvent(id);
      }, via: via);
    }
    entry
      ..remove('events')
      ..remove('etag')
      ..remove('modified')
      ..remove('hash')
      ..['stopped'] = true;
    final w = _watches.remove(s.id);
    if (w != null) unawaited(w.watcher.stop());
    if (!already || ids.isNotEmpty) {
      hub.log.info('A family stopped sharing their calendar; ${ids.length} copied event${ids.length == 1 ? '' : 's'} removed');
    }
    await _status(s, '${familyPhrase(from)} stopped sharing their calendar');
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

  /// Sets the subscription's status, which parents see under the calendar in the app. Never
  /// throws: a status that can't be written is only logged.
  Future<void> _status(Subscription s, String status) async {
    final entry = _entry(s.id);
    if (entry['status'] == status) return;
    entry['status'] = status;
    try {
      await hub.gate.asHub(() async {
        if (hub.den.subscription(s.id) != null) {
          await hub.den.setSubscriptionStatus(s.id, status.length > 500 ? status.substring(0, 500) : status);
        }
      });
    } on Object catch (e, st) {
      hub.log.warn('A calendar feed\'s status wasn\'t saved: ${describeError(e, st)}');
    }
  }

  /// Fetches one feed and applies it. Returns how many series it holds, or null when it failed,
  /// the hub is stopping, or it is catching up after a restore.
  Future<int?> syncOne(Subscription s) async {
    if (hub.catchingUp) return null;
    final entry = _entry(s.id);
    final fingerprint = _fingerprint(s);
    final changedConfig = entry['config'] != fingerprint;
    final fetched = await fetchFeed(
      hub.feedFetch,
      s.url,
      etag: changedConfig ? null : entry['etag'] as String?,
      modified: changedConfig ? null : entry['modified'] as String?,
    );
    if (_stopping || hub.catchingUp) return null;
    final share = shareWatchUri(s.url) != null;
    if (fetched.problem != null) {
      if (share && fetched.status == 401) {
        await _stoppedSharing(s);
        return null;
      }
      hub.log.warn('A calendar feed failed: ${fetched.temporary ? 'temporarily' : 'link broken'}');
      await _status(s, fetched.problem!);
      return null;
    }
    if (fetched.notModified && !changedConfig) return (entry['events'] as Map?)?.length ?? 0;
    final text = fetched.text!;
    final hash = hashToken(text);
    if (!changedConfig && entry['hash'] == hash) {
      entry
        ..['etag'] = fetched.etag
        ..['modified'] = fetched.modified;
      return (entry['events'] as Map?)?.length ?? 0;
    }
    final String label;
    final FeedPlan plan;
    final familyId = hub.den.familyId;
    try {
      final calendar = parseIcs(text, defaultZone: hub.zone);
      label = s.label.isNotEmpty ? s.label : (calendar.name ?? 'Calendar');
      plan = planFeed(calendar, s, now: hub.now(), label: label, own: (uid) => isOwnUid(uid, familyId));
      if (share) {
        entry['from'] = calendar.name;
        final family = calendar.events.map((e) => sharedFamilyOf(e.uid)).nonNulls.firstOrNull;
        if (family != null) entry['family'] = family;
      }
    } on IcsFormatException {
      await _status(s, 'That link isn\'t a calendar file.');
      return null;
    } on Object catch (e, st) {
      hub.log.warn('A calendar feed couldn\'t be read: ${describeError(e, st)}');
      await _status(s, 'Den couldn\'t read that calendar file. It will try again.');
      return null;
    }
    final applied = await _apply(s, plan, label);
    // Stopped part way: what was written is saved, and the next sync picks up from there.
    if (applied == null) return null;
    final (count, failed) = applied;
    entry
      ..['config'] = fingerprint
      ..['etag'] = fetched.etag
      ..['modified'] = fetched.modified
      ..['hash'] = hash
      ..remove('stopped');
    final unread = plan.skipped + failed;
    final wall = wallOf(hub.zone, hub.now());
    await _status(
      s,
      count == 0 && plan.own > 0 && unread == 0
          ? 'This is your own family\'s calendar, so Den leaves it out.'
          : '$count event${count == 1 ? '' : 's'}${unread == 0 ? '' : ' ($unread Den couldn\'t read)'}, updated ${clockText(wall)}',
    );
    hub.log.info('A calendar feed was updated${unread == 0 ? '' : '; $unread of its events couldn\'t be read'}');
    return count;
  }

  /// Writes [plan] into the subscription's space. Returns how many events the feed holds and
  /// how many Den couldn't write, or null when the hub started stopping part way.
  Future<(int, int)?> _apply(Subscription s, FeedPlan plan, String label) async {
    final entry = _entry(s.id);
    final mapped = <String, String>{...?(entry['events'] as Map?)?.cast<String, String>()};
    entry['events'] = mapped;
    final via = label;
    await _adopt(s, plan, mapped, via);
    var failed = 0;
    var unsaved = 0;
    for (final uid in plan.fields.keys) {
      if (_stopping) return null;
      final want = plan.fields[uid]!;
      try {
        final known = mapped[uid];
        final id = await hub.gate.asHub(() async {
          final existing = known == null ? null : hub.den.event(known);
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
        if (id != known && ++unsaved >= saveEvery) {
          unsaved = 0;
          await hub.state.save('feeds');
        }
        final series = plan.series[uid]!;
        if (series.rule != null) await _exceptions(id, series, s.targetSpace, via);
      } on Object catch (e, st) {
        failed++;
        hub.log.debug('A calendar feed event wasn\'t written: ${describeError(e, st)}');
      }
    }
    for (final uid in mapped.keys.where((u) => !plan.fields.containsKey(u)).toList()) {
      if (_stopping) return null;
      final id = mapped[uid]!;
      await hub.gate.asHub(() async {
        if (hub.den.event(id) != null) await hub.den.deleteEvent(id);
      }, via: via);
      mapped.remove(uid);
    }
    return (mapped.length, failed);
  }

  /// Finds the events of this feed whose ids weren't saved (a sync cut short before it saved
  /// them) by the UID each carries in `source.ref`, so this sync updates them instead of adding
  /// copies, and removes extra copies. Only imported events (`source.kind` `ics`) in the feed's
  /// space whose UID the feed still has, and that no other feed holds, are touched.
  Future<void> _adopt(Subscription s, FeedPlan plan, Map<String, String> mapped, String via) async {
    final claimed = <String>{
      for (final e in _doc.entries)
        if (e.key != s.id && e.value is Map) ...(((e.value as Map)['events'] as Map?)?.values.whereType<String>() ?? const <String>[]),
      ...mapped.values,
    };
    final wanted = {for (final uid in plan.fields.keys) feedRef(uid): uid};
    final extra = <String>[];
    await hub.gate.asHub<void>(() {
      final found = <String, List<Event>>{};
      for (final e in hub.den.events) {
        if (e.space != s.targetSpace || e.source.kind != 'ics' || claimed.contains(e.id)) continue;
        final uid = wanted[e.source.ref];
        if (uid != null) (found[uid] ??= []).add(e);
      }
      for (final f in found.entries) {
        // The oldest copy is the one people may already have seen; keep it.
        final copies = f.value..sort((a, b) => a.rec.created.compareTo(b.rec.created));
        final held = mapped[f.key];
        final heldEvent = held == null ? null : hub.den.event(held);
        if (heldEvent != null && heldEvent.space == s.targetSpace) {
          extra.addAll(copies.map((e) => e.id));
        } else {
          if (heldEvent != null) extra.add(heldEvent.id);
          mapped[f.key] = copies.first.id;
          extra.addAll(copies.skip(1).map((e) => e.id));
        }
      }
    });
    for (final id in extra) {
      await hub.gate.asHub(() async {
        if (hub.den.event(id) != null) await hub.den.deleteEvent(id);
      }, via: via);
    }
    if (extra.isNotEmpty) hub.log.info('Removed ${extra.length} repeated calendar feed event${extra.length == 1 ? '' : 's'}');
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
