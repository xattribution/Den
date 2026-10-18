// Prints what Den's own reader makes of sample text, for tuning the rules by eye.
// dart run tool/probe.dart [file]
import 'dart:convert';
import 'dart:io';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/demo.dart';

Future<void> main(List<String> args) async {
  final den = await createDemoFamily(now: DateTime.utc(2026, 10, 16, 13));
  final context = CaptureContext.of(den);
  final samples = args.isNotEmpty
      ? [File(args.first).readAsStringSync()]
      : [
          'soccer every Wednesday at 5 for Leo',
          'Dentist for Zoe next Tuesday at 3:30pm',
          'milk, eggs, 2 lb apples from Costco',
          'remind me to call the dentist tomorrow at 9',
          'Leo takes out the trash every Thursday night',
          'Maya and Leo take turns doing the dishes every night',
          'Picture day Thursday',
          'add sunscreen and beach towels to the packing list',
          'Piano lessons for Maya Tuesdays and Thursdays 4-5pm until Dec 17',
          'Lunch with Grandma Rosa at Luca\'s Friday at noon',
          'Permission slips due Monday',
          'we need paper towels, a dozen eggs and bananas',
        ];
  const enc = JsonEncoder.withIndent('  ');
  for (final s in samples) {
    stdout.writeln('=== $s');
    stdout.writeln(enc.convert(readWords(s, context)));
  }
  await den.close();
}
