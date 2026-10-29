/// The engine benchmarks as a test suite, skipped by default. On the VM and, compiled by
/// dart2js, in Chrome:
///
///     dart test -P benchmark
///     dart test -P benchmark -p chrome
@Tags(['benchmark'])
library;

import 'dart:convert';

import 'package:test/test.dart';

import '../benchmark/big_family.dart';
import '../benchmark/engine.dart';

void main() {
  test('engine benchmarks on a large family', () async {
    final channel = spawnHybridUri('/benchmark/hybrid_family.dart');
    final text = await channel.stream.first as String;
    final family = BigFamily.fromJson((jsonDecode(text) as Map).cast<String, Object?>())!;
    final results = await runEngineBenchmarks(family, runs: 5, log: print);
    print(table(results));
    for (final r in results) {
      expect(r.samples, isNotEmpty, reason: r.name);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
