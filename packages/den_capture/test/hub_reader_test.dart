import 'dart:convert';
import 'dart:typed_data';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

const claudeOnHub = {
  'kind': 'claude',
  'reader': {
    'id': 'claude',
    'name': 'Claude',
    'place': 'provider',
    'inputs': ['text', 'image', 'pdf'],
    'history_name': 'Claude',
  },
  'device_first': true,
  'model': 'claude-opus-5-5',
  'address': null,
  'key_saved': true,
};

void main() {
  late Den den;
  setUpAll(() async => den = await demo());
  tearDownAll(() => den.close());

  Future<Map<String, String>> sign(String method, Uri url, List<int> body) async =>
      {'x-den-device': 'PHONE', 'x-den-signature': '${method.toLowerCase()} ${url.path} ${body.length}'};

  test('what is shared travels to the hub and back whole', () {
    final input = CaptureInput.shared(
      subject: 'Flyer',
      text: 'Picture day Thursday',
      files: [CaptureFile(Uint8List.fromList(const [1, 2, 3]), 'image/png', name: 'flyer.png')],
    );
    final back = CaptureInput.fromJson(jsonDecode(jsonEncode(input.toJson())) as Map<String, Object?>);
    expect((back.kind, back.subject, back.text), (CaptureKind.photo, 'Flyer', 'Picture day Thursday'));
    expect(back.files.single.bytes, [1, 2, 3]);
    expect((back.files.single.mimeType, back.files.single.name), ('image/png', 'flyer.png'));
    expect(() => CaptureInput.fromJson({'kind': 'fax'}), throwsFormatException);
    expect(ReaderInfo.fromJson(ClaudeReader(apiKey: 'k').info.toJson())!.historyName, 'Claude');
  });

  test('the hub reader signs every call, tries the hub\'s addresses in order and remembers the one that answered', () async {
    final asked = <String>[];
    final client = MockClient((r) async {
      asked.add('${r.method} ${r.url.host} ${r.headers['x-den-signature']}');
      if (r.url.host == '10.0.0.9') throw http.ClientException('no route');
      if (r.url.path == '/api/v1/capture/reader') return http.Response(jsonEncode(claudeOnHub), 200);
      return http.Response(jsonEncode({'wire': _dentist, 'reader': claudeOnHub['reader']}), 200);
    });
    final hub = HubCaptureClient(
      bases: () => [Uri.parse('http://10.0.0.9:47733'), Uri.parse('http://192.168.1.20:47733')],
      sign: sign,
      client: client,
    );
    final reader = HubReader(hub);
    expect(await reader.available(), isTrue);
    expect(reader.info.name, 'Claude on the hub');
    expect(reader.info.place, ReaderPlace.provider);
    expect(reader.info.reads(ReaderInput.pdf), isTrue);

    final result = await Capturer(readers: [reader]).read(CaptureInput.typed('Dentist for Zoe Tuesday at 3:30'), den);
    expect(result.draft.events.single.title, 'Dentist');
    expect(result.draft.origin.reader, 'Claude');
    expect(asked, [
      'GET 10.0.0.9 get /api/v1/capture/reader 0',
      'GET 192.168.1.20 get /api/v1/capture/reader 0',
      startsWith('POST 192.168.1.20 post /api/v1/capture/read '),
    ]);
  });

  test('no hub in reach, or none set up, means the device reads on its own', () async {
    final away = HubReader(HubCaptureClient(bases: () => [Uri.parse('http://10.0.0.9:47733')], sign: sign, client: MockClient((_) async => throw http.ClientException('away'))));
    expect(await away.available(), isFalse);
    final bare = HubReader(HubCaptureClient(
      bases: () => [Uri.parse('http://192.168.1.20:47733')],
      sign: sign,
      client: MockClient((_) async => http.Response(jsonEncode(HubReaderStatus.none.toJson()), 200)),
    ));
    expect(await bare.available(), isFalse);
    final result = await Capturer(readers: [away, bare, const RulesReader()]).read(CaptureInput.typed('milk and eggs'), den);
    expect(result.reader.id, 'rules');
  });

  test('the hub\'s refusals reach people as they were said', () async {
    final hub = HubCaptureClient(
      bases: () => [Uri.parse('http://192.168.1.20:47733')],
      sign: sign,
      client: MockClient((r) async => http.Response(
            jsonEncode({
              'error': {'code': 'reader_failed', 'message': 'Claude is busy right now. Try again in a minute.', 'details': {'retry': true}},
            }),
            502,
          )),
    );
    await expectLater(
      hub.read(CaptureInput.typed('milk')),
      throwsA(isA<ReaderException>().having((e) => (e.message, e.retry), 'message', ('Claude is busy right now. Try again in a minute.', true))),
    );
  });

  test('the hub is asked what it reads with at most once a minute', () async {
    var calls = 0;
    var now = DateTime(2026, 10, 16, 8);
    final reader = HubReader(
      HubCaptureClient(
        bases: () => [Uri.parse('http://192.168.1.20:47733')],
        sign: sign,
        client: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode(claudeOnHub), 200);
        }),
      ),
      clock: () => now,
    );
    await reader.available();
    await reader.available();
    expect(calls, 1);
    now = now.add(const Duration(minutes: 2));
    await reader.available();
    expect(calls, 2);
  });
}

const _dentist = {
  'events': [
    {
      'title': 'Dentist',
      'date': '2026-10-20',
      'start': '15:30',
      'end': null,
      'endDate': null,
      'repeat': null,
      'people': ['Zoe'],
      'location': null,
      'notes': null,
      'kind': 'health',
      'remindBefore': <int>[],
    },
  ],
  'chores': <Object>[],
  'items': <Object>[],
  'reminders': <Object>[],
  'unclear': <Object>[],
};
