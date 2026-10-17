import 'package:den_core/den_core.dart';

/// Browsers keep the family in memory and sync it from the hub on every load.
Future<DenStorage> openDeviceStorage() async => MemoryStorage();
