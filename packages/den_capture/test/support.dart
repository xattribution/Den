import 'dart:convert';
import 'dart:io';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';

/// Friday, October 16, 2026, 8 AM in Chicago: the demo family's present.
final DateTime demoNow = DateTime.utc(2026, 10, 16, 13);

/// The Carter family on Alex's phone (Alex is a parent).
Future<Den> demo() => createDemoFamily(now: demoNow);

String fixtureText(String name) => File('test/fixtures/$name').readAsStringSync();

Map<String, Object?> fixtureJson(String name) => Map<String, Object?>.from(jsonDecode(fixtureText(name)) as Map);

String idOf(Den den, String name) => den.members.firstWhere((m) => m.name == name).id;

/// A reader that returns what it's told, recording what it was asked.
class FixedReader implements CaptureReader {
  FixedReader(this.wire, {this.id = 'fixed', this.inputs = const {ReaderInput.text}, this.ready = true, this.error});
  final Map<String, Object?> wire;
  final String id;
  final Set<ReaderInput> inputs;
  final bool ready;
  final ReaderException? error;
  final asked = <ReadRequest>[];

  @override
  ReaderInfo get info => ReaderInfo(id: id, name: id, place: ReaderPlace.device, inputs: inputs, historyName: id);

  @override
  Future<bool> available() async => ready;

  @override
  Future<Map<String, Object?>> read(ReadRequest request) async {
    asked.add(request);
    if (error != null) throw error!;
    return wire;
  }
}

/// Finds fixed text in any file, the way Vision or ML Kit would on a phone.
class FixedText implements TextFinder {
  FixedText(this.text);
  final String? text;
  int calls = 0;

  @override
  Future<String?> textIn(CaptureFile file) async {
    calls++;
    return text;
  }
}

const empty = <String, Object?>{'events': [], 'chores': [], 'items': [], 'reminders': [], 'unclear': []};
