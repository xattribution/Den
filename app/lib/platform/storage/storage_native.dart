import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_core/storage_io.dart';
import 'package:path_provider/path_provider.dart';

/// Phones, tablets and desktops keep the change log in the app's private support directory.
Future<DenStorage> openDeviceStorage() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}${Platform.pathSeparator}den');
  await dir.create(recursive: true);
  return FileStorage(dir.path);
}
