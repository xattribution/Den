/// package:test, with [test] reporting a failure as a GitHub Actions annotation too: the test's
/// name and what failed show on the pull request's checks, not only inside the job log.
library;

import 'dart:async';

import 'package:test/test.dart' as base;

export 'package:test/test.dart' hide test;

/// [base.test], with a failing body also printed as an `::error` workflow command.
void test(
  Object? description,
  FutureOr<void> Function() body, {
  String? testOn,
  base.Timeout? timeout,
  Object? skip,
  Object? tags,
  Map<String, Object?>? onPlatform,
  int? retry,
}) {
  base.test(
    description,
    () async {
      try {
        await body();
      } catch (e) {
        final text = '$description: $e'.replaceAll('%', '%25').replaceAll('\r', '').replaceAll('\n', '%0A');
        print('::error title=den_hub test failed::$text');
        rethrow;
      }
    },
    testOn: testOn,
    timeout: timeout,
    skip: skip,
    tags: tags,
    onPlatform: onPlatform,
    retry: retry,
  );
}
