import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Golden images are rendered on Windows, where the people reviewing them work. Other platforms
/// rasterize text differently, so there (CI runs on Linux) every screen still renders, catching
/// overflows and exceptions, but its pixels aren't compared.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (!Platform.isWindows && !autoUpdateGoldenFiles) goldenFileComparator = _RenderOnly();
  await testMain();
}

class _RenderOnly extends GoldenFileComparator {
  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {}
}
