import 'package:den_core/den_core.dart';

Future<DenStorage> openDeviceStorage({String name = 'den'}) async => MemoryStorage();

Future<void> deleteDeviceStorage(String name) async {}
