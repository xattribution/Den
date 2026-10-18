import 'dart:convert';
import 'dart:typed_data';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Den den;
  late CaptureContext context;
  setUpAll(() async {
    den = await demo();
    context = CaptureContext.of(den);
  });
  tearDownAll(() => den.close());

  final jpeg = CaptureFile(Uint8List.fromList(const [0xff, 0xd8, 0xff, 0xe0]), 'image/jpeg', name: 'flyer.jpg');
  final pdf = CaptureFile(Uint8List.fromList(utf8.encode('%PDF-1.7')), 'application/pdf', name: 'schedule.pdf');

  group('Claude', () {
    test('sends the photo, the facts and the schema as one structured-output request', () async {
      late http.Request sent;
      final reader = ClaudeReader(
        apiKey: ' sk-ant-test ',
        client: MockClient((r) async {
          sent = r;
          return http.Response(fixtureText('claude_flyer.json'), 200);
        }),
      );
      expect(await reader.available(), isTrue);
      final wire = await reader.read(ReadRequest(CaptureInput.shared(files: [jpeg, pdf]), context));
      expect((wire['events'] as List).length, 6);

      expect(sent.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(sent.headers['x-api-key'], 'sk-ant-test');
      expect(sent.headers['anthropic-version'], '2023-06-01');
      expect(sent.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
      expect(sent.headers.containsKey('anthropic-dangerous-direct-browser-access'), isFalse);
      final body = jsonDecode(sent.body) as Map<String, Object?>;
      expect(body['model'], 'claude-opus-5-5');
      expect(body['fallbacks'], 'default');
      expect(body['system'], CaptureWire.instructions);
      expect(body.containsKey('thinking'), isFalse);
      final config = body['output_config'] as Map;
      expect(config['effort'], 'medium');
      expect(config['format'], {'type': 'json_schema', 'schema': CaptureWire.schema});
      final content = ((body['messages'] as List).single as Map)['content'] as List;
      expect([for (final c in content) (c as Map)['type']], ['image', 'document', 'text']);
      expect((content[0] as Map)['source'], {'type': 'base64', 'media_type': 'image/jpeg', 'data': base64Encode(jpeg.bytes)});
      expect(((content[1] as Map)['source'] as Map)['media_type'], 'application/pdf');
      expect((content[2] as Map)['text'], contains('They shared a PDF (attached above):'));
    });

    test('in a browser, opts in to direct calls; Haiku goes without the fallback it doesn\'t have', () async {
      final browser = ClaudeReader(apiKey: 'k', browser: true, model: 'claude-haiku-5-5');
      expect(browser.headers['anthropic-dangerous-direct-browser-access'], 'true');
      expect(browser.headers.containsKey('anthropic-beta'), isFalse);
      expect(browser.body(ReadRequest(CaptureInput.typed('milk'), context)).containsKey('fallbacks'), isFalse);
    });

    test('no key, no Claude', () async {
      expect(await ClaudeReader(apiKey: '  ').available(), isFalse);
    });

    test('reads the recorded answers to an email', () {
      final wire = ClaudeReader.parse(200, fixtureText('claude_email.json'));
      final draft = draftFrom(wire, context, origin: const CaptureOrigin(CaptureKind.email, reader: 'Claude'));
      final game = draft.events.first;
      expect((game.title, game.date, game.start), ('Soccer game vs. the Hawks', '2026-10-24', '09:00'));
      expect(game.issues.map((i) => i.message), ['No one in the family is called Coach Dan']);
      final practice = draft.events.last;
      expect(practice.rrule, 'FREQ=WEEKLY;BYDAY=TU,TH');
      expect([for (final i in draft.items) (i.text, i.qty, i.store)], [('Orange slices', null, null), ('Water bottles', '24', 'Costco')]);
      expect(draft.reminders.single.person, idOf(den, 'Alex'));
      expect(draft.unclear, ['The team photo date is still to be announced']);
    });

    test('a refusal, a cut-off answer and a bad key are said for people', () {
      expect(
        () => ClaudeReader.parse(200, fixtureText('claude_refusal.json')),
        throwsA(isA<ReaderException>().having((e) => e.message, 'message', 'Claude declined to read that.')),
      );
      expect(
        () => ClaudeReader.parse(200, jsonEncode({'stop_reason': 'max_tokens', 'content': []})),
        throwsA(isA<ReaderException>().having((e) => e.message, 'message', contains('too much to read'))),
      );
      expect(
        () => ClaudeReader.parse(401, fixtureText('claude_bad_key.json')),
        throwsA(isA<ReaderException>().having((e) => e.message, 'message', contains('didn\'t accept the API key'))),
      );
      expect(
        () => ClaudeReader.parse(529, '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'),
        throwsA(isA<ReaderException>().having((e) => e.retry, 'retry', isTrue)),
      );
      expect(
        () => ClaudeReader.parse(200, jsonEncode({'stop_reason': 'end_turn', 'content': [{'type': 'text', 'text': 'Sorry'}]})),
        throwsA(isA<ReaderException>()),
      );
    });

    test('an image type Claude can\'t take, or no network, says what to do', () async {
      final heic = CaptureFile(Uint8List(4), 'image/heic');
      final reader = ClaudeReader(apiKey: 'k', client: MockClient((_) async => throw http.ClientException('offline')));
      await expectLater(
        reader.read(ReadRequest(CaptureInput.shared(files: [heic]), context)),
        throwsA(isA<ReaderException>().having((e) => e.message, 'message', contains('JPEG or PNG'))),
      );
      await expectLater(
        reader.read(ReadRequest(CaptureInput.typed('milk'), context)),
        throwsA(isA<ReaderException>().having((e) => e.message, 'message', contains('Couldn\'t reach Claude'))),
      );
    });
  });

  group('Home model', () {
    test('asks Ollama for the schema and reads its answer', () async {
      late http.Request sent;
      final reader = HomeModelReader(
        base: HomeModelReader.baseFor('192.168.1.20')!,
        client: MockClient((r) async {
          if (r.url.path == '/api/tags') return http.Response('{"models":[]}', 200);
          sent = r;
          return http.Response(fixtureText('ollama_chat.json'), 200);
        }),
      );
      expect(reader.base.toString(), 'http://192.168.1.20:11434');
      expect(await reader.available(), isTrue);
      final wire = await reader.read(ReadRequest(CaptureInput.typed('Dentist for Zoe Tuesday at 3:30'), context));
      final body = jsonDecode(sent.body) as Map<String, Object?>;
      expect((body['model'], body['stream']), ('llama3.2', false));
      expect(body['format'], CaptureWire.schema);
      expect(((body['messages'] as List).first as Map)['content'], CaptureWire.instructions);
      final draft = draftFrom(wire, context, origin: const CaptureOrigin(CaptureKind.typed, reader: 'the home model'));
      expect(draft.events.single.reminders, [1440]);
    });

    test('a computer that doesn\'t answer isn\'t available; a missing model says how to get it', () async {
      final away = HomeModelReader(base: Uri.parse('http://10.0.0.9:11434'), client: MockClient((_) async => throw http.ClientException('no route')));
      expect(await away.available(), isFalse);
      expect(
        () => HomeModelReader.parse(404, '{"error":"model not found"}', 'llama3.2'),
        throwsA(isA<ReaderException>().having((e) => e.message, 'message', contains('ollama pull llama3.2'))),
      );
    });
  });

  group('Den\'s own reader', () {
    test('runs everywhere and reads only text', () async {
      const reader = RulesReader();
      expect(await reader.available(), isTrue);
      expect(reader.info.place, ReaderPlace.device);
      expect(reader.info.historyName, isNull);
      expect(reader.info.reads(ReaderInput.image), isFalse);
    });
  });

  test('lenient JSON finds the object in a model\'s chatter', () {
    expect(lenientJson('Sure! ```json\n{"events": []}\n``` Hope that helps.'), {'events': []});
    expect(lenientJson('no json here'), isNull);
    expect(lenientJson('{broken'), isNull);
  });
}
