/// Builds the benchmark family once and keeps it under `.dart_tool/den_benchmark/`.
library;

import 'dart:convert';
import 'dart:io';

import 'big_family.dart';

File get _cache => File('.dart_tool/den_benchmark/big_family_v$bigFamilyVersion.json');

/// The cached family, or a new one (a minute or two) that is then cached.
Future<BigFamily> loadOrBuildBigFamily({void Function(String)? progress}) async {
  final text = await loadOrBuildBigFamilyJson(progress: progress);
  return BigFamily.fromJson((jsonDecode(text) as Map).cast<String, Object?>())!;
}

/// [loadOrBuildBigFamily] as JSON text, for sending to a browser.
Future<String> loadOrBuildBigFamilyJson({void Function(String)? progress}) async {
  final file = _cache;
  if (await file.exists()) {
    final text = await file.readAsString();
    final json = jsonDecode(text);
    if (json is Map && BigFamily.fromJson(json.cast<String, Object?>()) != null) return text;
  }
  progress?.call('Building the benchmark family (signing takes a minute or two)...');
  final family = await buildBigFamily(progress: progress);
  final text = jsonEncode(family.toJson());
  await file.parent.create(recursive: true);
  await file.writeAsString(text);
  return text;
}
