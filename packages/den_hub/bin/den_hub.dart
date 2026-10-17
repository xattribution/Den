import 'dart:io';

import 'src/cli.dart';

/// `den_hub`: serve, mcp, import-sett, setup-code, status, backup, restore.
Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
  await stdout.flush();
  exit(exitCode);
}
