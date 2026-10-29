/// Runs the engine benchmarks on the Dart VM and prints a Markdown table:
///
///     dart run benchmark/main.dart [runs]
///
/// For dart2js numbers, run the same suite in Chrome: `dart test -P benchmark -p chrome`.
library;

import 'engine.dart';
import 'family_cache.dart';

Future<void> main(List<String> args) async {
  final runs = args.isEmpty ? 7 : int.parse(args.first);
  final family = await loadOrBuildBigFamily(progress: print);
  final results = await runEngineBenchmarks(family, runs: runs, log: print);
  print('');
  print(table(results));
}
