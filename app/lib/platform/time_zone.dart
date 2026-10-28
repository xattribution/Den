import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/timezone.dart' as tz;

import '../design/pickers/time_zone_picker.dart' show commonZones;

/// This device's IANA time zone, or a best guess from its UTC offset, or UTC.
Future<String> deviceTimeZone() async {
  try {
    final info = await FlutterTimezone.getLocalTimezone();
    if (tz.timeZoneDatabase.locations.containsKey(info.identifier)) return info.identifier;
  } on Object catch (e) {
    debugPrint('Time zone lookup failed: $e');
  }
  final offset = DateTime.now().timeZoneOffset;
  final now = DateTime.now().millisecondsSinceEpoch;
  for (final name in commonZones.keys) {
    final loc = tz.timeZoneDatabase.locations[name];
    if (loc != null && loc.timeZone(now).offset == offset) return name;
  }
  return 'UTC';
}
