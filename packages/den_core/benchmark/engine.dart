/// The engine benchmarks: what a family of six with two years of history costs to open, to
/// catch up with a partner's offline week, and to answer the screens after one change. Pure
/// Dart, so the same suite runs on the VM (`benchmark/main.dart`) and, compiled by dart2js, in
/// Chrome (`dart test -P benchmark -p chrome`).
library;

import 'dart:async';

import 'package:den_core/den_core.dart';

import 'big_family.dart';

/// One measured scenario: wall-clock milliseconds per run.
class Result {
  Result(this.name, this.samples);
  final String name;
  final List<double> samples;

  double get median {
    final s = [...samples]..sort();
    return s.isEmpty ? double.nan : s[s.length ~/ 2];
  }

  double get min => samples.reduce((a, b) => a < b ? a : b);

  @override
  String toString() => '$name: median ${median.toStringAsFixed(2)} ms, min ${min.toStringAsFixed(2)} ms (${samples.length} runs)';
}

/// Times [body] in milliseconds.
Future<double> timed(FutureOr<void> Function() body) async {
  final sw = Stopwatch()..start();
  await body();
  return sw.elapsedMicroseconds / 1000;
}

/// Opens the founder's phone over [storage] at the family's [BigFamily.now].
Future<Den> openFounder(BigFamily f, DenStorage storage) async =>
    Den.open(storage: storage, keys: await f.keys(), now: () => f.now);

/// Storage as the founder's phone leaves it after a session: opened once and closed, so anything
/// the engine keeps between launches is there.
Future<JsonStorage> settledStorage(BigFamily f) async {
  final storage = f.founderStorage();
  final den = await openFounder(f, storage);
  den.today();
  await den.close();
  return storage;
}

/// Runs every scenario [runs] times (after one warm-up run each) and returns the results.
Future<List<Result>> runEngineBenchmarks(BigFamily f, {int runs = 5, void Function(String)? log}) async {
  final results = <Result>[];
  void done(Result r) {
    results.add(r);
    log?.call(r.toString());
  }

  final settled = await settledStorage(f);
  log?.call('log: ${f.log.length} changes; partner offline week: ${f.partnerWeek.length}');

  // Cold open: from stored text to a ready engine, then to Today's first answer.
  {
    final open = <double>[], first = <double>[];
    for (var i = 0; i <= runs; i++) {
      final storage = settled.copy();
      late Den den;
      final o = await timed(() async => den = await openFounder(f, storage));
      final t = await timed(() => den.today());
      await den.close();
      if (i == 0) continue;
      open.add(o);
      first.add(o + t);
    }
    done(Result('cold open', open));
    done(Result('cold open + first today()', first));
  }

  // A partner who was offline for a week: one change, then all 500.
  final week = f.partnerChanges();
  for (final n in [1, week.length]) {
    final samples = <double>[];
    for (var i = 0; i <= runs; i++) {
      final den = await openFounder(f, settled.copy());
      final batch = week.take(n).toList();
      final ms = await timed(() async {
        final r = await den.ingest(batch);
        if (r.added != n) throw StateError('ingested ${r.added} of $n');
      });
      await den.close();
      if (i > 0) samples.add(ms);
    }
    done(Result(n == 1 ? 'ingest 1 out-of-order change' : 'ingest $n out-of-order changes', samples));
  }

  // Views after a one-record change, as a screen asks for them again.
  {
    final den = await openFounder(f, settled.copy());
    final today = den.todayDate();
    final weekStart = today;
    final items = den.list(f.groceries)!.items.where((i) => !i.checked).map((i) => i.id).toList();
    var next = 0;
    Future<void> checkOne() => den.setItemChecked(items[next++ % items.length], true);
    var done1 = false;
    Future<void> toggleChore() => den.setChoreDone(f.choreToday, today, done1 = !done1);
    den.today();
    den.week(weekStart);
    den.choresOn(today);
    for (final (label, change) in [('item', checkOne), ('completion', toggleChore)]) {
      final t = <double>[], w = <double>[], c = <double>[];
      for (var i = 0; i <= runs; i++) {
        await change();
        final tt = await timed(() => den.today());
        await change();
        final ww = await timed(() => den.week(weekStart));
        await change();
        final cc = await timed(() => den.choresOn(today));
        if (i == 0) continue;
        t.add(tt);
        w.add(ww);
        c.add(cc);
      }
      done(Result('today() after one $label change', t));
      done(Result('week() after one $label change', w));
      done(Result('choresOn(today) after one $label change', c));
    }

    // Checking one grocery item end to end: the write, then what the app shows again for it.
    final e2e = <double>[];
    for (var i = 0; i <= runs; i++) {
      final ms = await timed(() async {
        await checkOne();
        den.today();
        den.lists;
      });
      if (i > 0) e2e.add(ms);
    }
    done(Result('check one list item, end to end', e2e));
    await den.close();
  }
  return results;
}

/// The results as a Markdown table.
String table(List<Result> results, {String heading = 'median ms'}) {
  final out = StringBuffer('| Scenario | $heading |\n|---|---:|\n');
  for (final r in results) {
    out.writeln('| ${r.name} | ${r.median.toStringAsFixed(r.median < 10 ? 2 : 0)} |');
  }
  return out.toString();
}
