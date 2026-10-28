import 'dart:async';

/// The tests here run in Chrome, where the golden setup one folder up (which asks dart:io which
/// platform this is) can't load; they compare no images.
Future<void> testExecutable(FutureOr<void> Function() testMain) async => testMain();
