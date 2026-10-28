import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Golden images are screenshots for review, not pixel assertions. They are rendered on CI
/// (Linux, with the real bundled fonts) by the screenshots workflow and committed from there
/// (DESIGN.md, "Screenshots"). Every test still renders its screen, so overflows and exceptions
/// fail on any machine, but pixels are never compared: text rasterizes differently from one
/// platform to the next. `flutter test --update-goldens` writes the images.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (!autoUpdateGoldenFiles) goldenFileComparator = _RenderOnly();
  await testMain();
}

class _RenderOnly extends GoldenFileComparator {
  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {}
}
