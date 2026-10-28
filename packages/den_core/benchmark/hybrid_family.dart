/// Runs on the VM next to a browser test and sends it the benchmark family as JSON, since a
/// browser can't read `.dart_tool/` (or sign 15,000 changes in reasonable time).
library;

import 'family_cache.dart';

/// [channel] is the test runner's `StreamChannel`.
Future<void> hybridMain(dynamic channel) async {
  channel.sink.add(await loadOrBuildBigFamilyJson());
}
