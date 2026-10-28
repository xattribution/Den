import 'dart:io';

import 'package:path_provider/path_provider.dart';
import '../../../platform/capabilities.dart';

/// Desktop: writes the export into Downloads (or Documents) and returns where it went.
Future<String?> saveExportToDisk(String fileName, List<int> bytes) async {
  if (!Capabilities.savesToFolder) return null;
  final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return dir.path.split(Platform.pathSeparator).last;
}
