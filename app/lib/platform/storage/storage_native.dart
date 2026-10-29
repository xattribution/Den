import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_core/storage_io.dart';
import 'package:path_provider/path_provider.dart';

/// Phones, tablets and desktops keep a log's changes in the app's private support directory:
/// `den/` for the first family, `den-<id>/` beside it for each other one.
Future<DenStorage> openDeviceStorage({String name = 'den'}) async {
  final dir = await _dir(name);
  await dir.create(recursive: true);
  return FileStorage(dir.path);
}

/// Deletes the log [name] kept on this device: a family this device left.
Future<void> deleteDeviceStorage(String name) async {
  final dir = await _dir(name);
  if (await dir.exists()) await dir.delete(recursive: true);
}

Future<Directory> _dir(String name) async {
  final base = await getApplicationSupportDirectory();
  return Directory('${base.path}${Platform.pathSeparator}$name');
}
