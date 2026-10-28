import 'dart:async';
import 'dart:io';

import 'src/cli.dart';

/// `den_hub`: serve, mcp, import-sett, setup-code, status, backup, restore.
///
/// Runs in a guarded zone: an error nothing caught (a malformed packet, a notifier that failed
/// in an unexpected way) is logged and the hub keeps serving, instead of the process exiting
/// and a restart policy looping on it.
Future<void> main(List<String> args) async {
  final done = Completer<int>();
  runZonedGuarded(() {
    unawaited(runCli(args).then(done.complete, onError: (Object e, StackTrace st) {
      stderr.writeln('den_hub stopped: ${e.runtimeType}');
      if (!done.isCompleted) done.complete(70);
    }));
  }, (error, stack) {
    stderr.writeln('${DateTime.now().toUtc().toIso8601String()} ERROR Uncaught ${error.runtimeType}; the hub keeps running');
  });
  exitCode = await done.future;
  await stdout.flush();
  exit(exitCode);
}
