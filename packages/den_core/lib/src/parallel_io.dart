import 'dart:io';
import 'dart:isolate';

/// Worker isolates to spread signature checks over: one per core, up to four.
int get workers {
  final n = Platform.numberOfProcessors;
  return n < 1 ? 1 : (n > 4 ? 4 : n);
}

/// Runs [work] in a new isolate.
Future<T> run<T>(Future<T> Function() work) => Isolate.run(work);
