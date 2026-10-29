import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/test.dart';

import 'support/fixture.dart';

String claudeFixture(String name) => File('../den_capture/test/fixtures/$name').readAsStringSync();

/// Anthropic's side, recorded: answers every Messages API call with [answer] and keeps what
/// it was sent.
class FakeAnthropic {
  FakeAnthropic(this.answer, {this.status = 200});
  String answer;
  int status;
  final sent = <http.Request>[];
  late final client = MockClient((r) async {
    if (r.url.host != 'api.anthropic.com') return http.Response('not here', 404);
    sent.add(r);
    return http.Response(answer, status);
  });
}

/// A device in the Carter family that can talk to the hub, signing with its own key.
class Phone {
  Phone(this.den, this.hub);
  final Den den;
  final HubFixture hub;

  Future<Map<String, String>> sign(String method, Uri url, List<int> body) => DeviceRequest.sign(
        keys: den.keys,
        method: method,
        url: url,
        body: body,
        hub: hub.hubDen.deviceId,
        actorId: den.actor?.id,
      );

  HubCaptureClient get client => HubCaptureClient(bases: () => [hub.base], sign: sign);
}

void main() {
  late HubFixture f;
  late FakeAnthropic anthropic;
  late Directory dir;
  late Phone alex;
  late Phone maya;
  late Phone leo;
  late Phone kitchen;
  final logged = <String>[];

  /// A personal device approved by Alex's phone for [name], or a shared display.
  Future<Den> device(String? name, {DeviceMode mode = DeviceMode.personal}) async {
    final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
    final member = name == null ? null : f.id(name);
    await d.requestJoin(
      familyId: f.phone.familyId!,
      founderPubkey: f.phone.founderPubkey!,
      deviceName: '${name ?? 'Kitchen'} device',
      kind: mode == DeviceMode.shared ? DeviceKind.display : DeviceKind.phone,
      mode: mode,
      memberId: member,
    );
    await f.phone.ingest(d.changesSince(const {}));
    await f.phone.approveDevice(d.deviceId, member: member, mode: mode);
    await d.ingest(f.phone.changesSince(d.versionVector, spaces: f.phone.spacesForDevice(d.deviceId)), through: f.phone.completeVector);
    return d;
  }

  setUp(() async {
    logged.clear();
    dir = await Directory.systemTemp.createTemp('den-capture-hub');
    anthropic = FakeAnthropic(claudeFixture('claude_email.json'));
    f = await HubFixture.start(
      dataDir: dir.path,
      configure: (base) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        dataDir: dir.path,
        log: HubLog(level: LogLevel.warn, sink: logged.add),
        httpClient: anthropic.client,
      ),
    );
    alex = Phone(f.phone, f);
    maya = Phone(await device('Maya'), f);
    leo = Phone(await device('Leo'), f);
    kitchen = Phone(await device(null, mode: DeviceMode.shared), f);
    await f.toHub();
  });

  tearDown(() async {
    await maya.den.close();
    await leo.den.close();
    await kitchen.den.close();
    await f.stop();
    await dir.delete(recursive: true);
  });

  const claude = HubReaderSetup(kind: HubReaderKind.claude, key: 'sk-ant-api03-family-key', model: 'claude-sonnet-5-5');

  test('without a device\'s signature, the hub says nothing', () async {
    final r = await f.call('GET', '/api/v1/capture/reader');
    expect(r.status, 401);
    final token = await f.token(scopes: {Scope.read});
    expect((await f.call('GET', '/api/v1/capture/reader', token: token)).status, 401, reason: 'API tokens don\'t open capture');
  });

  test('a parent sets the reader once; every device sees it, and nobody sees the key', () async {
    expect((await maya.client.status())!.ready, isFalse);
    final set = await alex.client.configure(claude);
    expect(set.ready, isTrue);
    expect(set.reader!.name, 'Claude');
    expect(set.reader!.place, ReaderPlace.provider);
    expect(set.reader!.reads(ReaderInput.image), isTrue);
    expect((set.model, set.keySaved, set.deviceFirst), ('claude-sonnet-5-5', true, true));

    final seen = await maya.client.status();
    expect(seen!.ready, isTrue);
    final raw = await apiCall(f.base, 'GET', '/api/v1/capture/reader', headers: await maya.sign('GET', f.base.replace(path: '/api/v1/capture/reader'), const []));
    expect(raw.text, isNot(contains('sk-ant')));

    final saved = File('${dir.path}/hub/capture.json').readAsStringSync();
    expect(saved, contains('sk-ant-api03-family-key'), reason: 'kept in the hub\'s own data directory');
    expect(f.hubDen.changesSince(const {}).any((c) => jsonEncode(c.fields).contains('sk-ant')), isFalse,
        reason: 'never in the family\'s log');
  });

  test('changing the model keeps the saved key; switching off forgets it', () async {
    await alex.client.configure(claude);
    final kept = await alex.client.configure(const HubReaderSetup(kind: HubReaderKind.claude, model: 'claude-opus-5-5'));
    expect((kept.ready, kept.model, kept.keySaved), (true, 'claude-opus-5-5', true));
    final off = await alex.client.configure(const HubReaderSetup(kind: HubReaderKind.none));
    expect((off.ready, off.keySaved), (false, false));
    expect(File('${dir.path}/hub/capture.json').readAsStringSync(), isNot(contains('sk-ant')));
  });

  test('only a parent\'s own device chooses the reader', () async {
    await expectLater(maya.client.configure(claude), throwsA(isA<ReaderException>().having((e) => e.message, 'message', contains('parent'))));
    kitchen.den.actAs(f.id('Alex'));
    await expectLater(kitchen.client.configure(claude), throwsA(isA<ReaderException>()));
    await expectLater(
      alex.client.configure(const HubReaderSetup(kind: HubReaderKind.claude, key: 'not-a-key')),
      throwsA(isA<ReaderException>().having((e) => e.message, 'message', contains('sk-ant-'))),
    );
    await expectLater(
      alex.client.configure(const HubReaderSetup(kind: HubReaderKind.claude)),
      throwsA(isA<ReaderException>().having((e) => e.message, 'message', 'Claude needs an API key.')),
    );
  });

  test('a teen\'s phone reads through the hub; her phone resolves, checks and writes as her', () async {
    await alex.client.configure(claude);
    final hubReader = HubReader(maya.client);
    final result = await Capturer(readers: [hubReader]).read(
      CaptureInput.shared(subject: 'Tigers U10 schedule', text: 'Game Saturday Oct 24 at 9 vs. the Hawks.'),
      maya.den,
    );
    expect(result.reader.name, 'Claude on the hub');
    expect(result.draft.origin, const CaptureOrigin(CaptureKind.email, reader: 'Claude'));

    final asked = jsonDecode(anthropic.sent.single.body) as Map<String, Object?>;
    expect(asked['model'], 'claude-sonnet-5-5');
    expect(anthropic.sent.single.headers['x-api-key'], 'sk-ant-api03-family-key');
    final prompt = ((((asked['messages'] as List).single as Map)['content'] as List).last as Map)['text'] as String;
    expect(prompt, contains('Maya (kid, the person sharing)'), reason: 'the hub reads as the person sharing');
    expect(prompt, contains('Game Saturday Oct 24'));

    final receipt = await writeDraft(maya.den, result.draft);
    final added = maya.den.history(limit: 20).where((h) => h.from != null).toList();
    expect(added, isNotEmpty);
    expect(added.every((h) => h.actor == f.id('Maya') && h.from!.reader == 'Claude'), isTrue);
    expect(receipt.keys, contains('i0'));
  });

  test('reads count against the family\'s AI budget and a kid\'s day, as GET /api/v1/assistant shows', () async {
    await alex.client.configure(claude);
    // A cent a month: the recorded answer costs about 0.87 of one with Sonnet's prices.
    await f.phone.updateFamily({'assistant': const AssistantPolicy(kidDailyLimit: 2, budgetCents: 1).toJson()});
    await f.toHub();
    await maya.client.read(CaptureInput.typed('milk'));
    Future<Map<String, Object?>> status(Phone p) async {
      final url = f.base.replace(path: '/api/v1/assistant');
      final r = await apiCall(f.base, 'GET', '/api/v1/assistant', headers: await p.sign('GET', url, const []));
      expect(r.status, 200, reason: r.text);
      return r.body;
    }

    var seen = await status(maya);
    expect(seen['you'], containsPair('used_today', 1));
    expect(seen['you'], containsPair('captures_today', 1));
    final month = (seen['this_month'] as Map).cast<String, Object?>();
    expect(month['spent_cents'], 1);
    expect(month['captures'], {'reads': 1, 'spent_cents': 1, 'stopped': false});

    await maya.client.read(CaptureInput.typed('eggs'));
    await expectLater(
      maya.client.read(CaptureInput.typed('bread')),
      throwsA(isA<ReaderException>().having((e) => e.message, 'message', startsWith('That\'s all Den can read for Maya today'))),
    );
    await expectLater(
      alex.client.read(CaptureInput.typed('bread')),
      throwsA(isA<ReaderException>().having((e) => e.message, 'message', startsWith('Reading with Claude has used this month\'s AI budget'))),
    );
    expect(anthropic.sent, hasLength(2), reason: 'nothing past the limits reaches Claude');
    seen = await status(alex);
    expect((seen['this_month'] as Map)['captures'], {'reads': 2, 'spent_cents': 2, 'stopped': true});
    // An assistant reading through the API's add_from_text is held to the same budget: Den's
    // own reader reads it instead of Claude.
    final token = await f.token(scopes: {Scope.read, Scope.lists});
    final api = await f.call('POST', '/api/v1/actions/add_from_text', token: token, body: {'text': 'milk'});
    expect((api.body['result'] as Map)['reader'], 'Den', reason: api.text);
    expect(anthropic.sent, hasLength(2));
  });

  test('someone who can\'t add anything, or a display nobody signed in to, can\'t spend the family\'s reader', () async {
    await alex.client.configure(claude);
    await expectLater(
      leo.client.read(CaptureInput.typed('milk')),
      throwsA(isA<ReaderException>().having((e) => e.message, 'message', 'Leo can\'t add anything Den reads.')),
    );
    await expectLater(
      kitchen.client.read(CaptureInput.typed('milk')),
      throwsA(isA<ReaderException>().having((e) => e.message, 'message', 'Sign in on this screen to add things.')),
    );
    expect(anthropic.sent, isEmpty);
  });

  test('with no reader set up, the hub says so; a device then reads on its own', () async {
    await expectLater(
      maya.client.read(CaptureInput.typed('milk')),
      throwsA(isA<ReaderException>().having((e) => e.message, 'message', startsWith('The hub has nothing to read with yet.'))),
    );
    final result = await Capturer(readers: [HubReader(maya.client), const RulesReader()]).read(CaptureInput.typed('milk and eggs'), maya.den);
    expect(result.reader.id, 'rules');
  });

  test('Claude being busy comes back as something to try again', () async {
    await alex.client.configure(claude);
    anthropic
      ..answer = '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'
      ..status = 529;
    await expectLater(
      maya.client.read(CaptureInput.typed('soccer Wednesday at 5')),
      throwsA(isA<ReaderException>().having((e) => e.retry, 'retry', isTrue)),
    );
  });

  test('a home model reads text; a photo alone needs the device to find its words first', () async {
    await alex.client.configure(const HubReaderSetup(kind: HubReaderKind.home, address: '192.168.1.30'));
    final status = await maya.client.status();
    expect((status!.reader!.place, status.reader!.reads(ReaderInput.image), status.address), (ReaderPlace.home, false, '192.168.1.30'));
    final photo = CaptureFile(Uint8List.fromList(const [0xff, 0xd8]), 'image/jpeg');
    await expectLater(
      maya.client.read(CaptureInput.shared(files: [photo])),
      throwsA(isA<ReaderException>().having((e) => e.message, 'message', contains('reads text'))),
    );
  });

  test('a signed request works once', () async {
    final url = f.base.replace(path: '/api/v1/capture/reader');
    final headers = await maya.sign('GET', url, const []);
    expect((await apiCall(f.base, 'GET', '/api/v1/capture/reader', headers: headers)).status, 200);
    expect((await apiCall(f.base, 'GET', '/api/v1/capture/reader', headers: headers)).status, 401);
  });

  /// Starts `POST /api/v1/capture/read` by hand on [socket] with [headers], announcing [length]
  /// bytes and sending [sent] of them (all by default).
  Future<void> post(Socket socket, Map<String, String> headers, {required int length, int? sent}) async {
    socket.write('POST /api/v1/capture/read HTTP/1.1\r\nHost: 127.0.0.1:${f.hub.port}\r\n'
        'Content-Type: application/json\r\nContent-Length: $length\r\n');
    headers.forEach((k, v) => socket.write('$k: $v\r\n'));
    socket.write('\r\n');
    socket.add(List.filled(sent ?? length, 0x20));
    await socket.flush();
  }

  /// The start of the hub's answer on [socket] (or throws if none comes).
  Future<String> answer(Socket socket) async {
    try {
      return utf8.decode(await socket.first.timeout(const Duration(seconds: 10)), allowMalformed: true);
    } finally {
      socket.destroy();
    }
  }

  Map<String, String> forged(String nonce) => {
        'x-den-device': f.hubDen.deviceId,
        'x-den-time': '${DateTime.now().millisecondsSinceEpoch}',
        'x-den-nonce': nonce,
        'x-den-signature': base64Url.encode(List.filled(64, 0)),
      };

  test('a device that signs its body\'s hash in the headers is checked before the body is read', () async {
    await alex.client.configure(claude);
    String hex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
    final hashed = HubCaptureClient(
      bases: () => [f.base],
      sign: (method, url, body) async =>
          {...await maya.sign(method, url, body), 'x-den-body-sha256': hex(const DartSha256().hashSync(body).bytes)},
    );
    expect((await hashed.status())!.ready, isTrue);
    expect((await hashed.read(CaptureInput.typed('Game Saturday Oct 24 at 9')))['wire'], isA<Map<String, Object?>>());

    // The hub's own device id is no secret. Naming it with a made-up signature over a claimed
    // hash is refused while nearly 20 MB are still unsent: the hub doesn't wait for the body.
    final socket = await Socket.connect('127.0.0.1', f.hub.port);
    addTearDown(socket.destroy);
    await post(socket, {...forged('n1'), 'x-den-body-sha256': '0' * 64}, length: 20 * 1024 * 1024, sent: 1024);
    await eventually(() => logged.any((l) => l.contains('Refused a signed request: bad-signature')));
  });

  test('a body whose signature can only be checked once it is in is read one per client at a time', () async {
    final slow = await Socket.connect('127.0.0.1', f.hub.port);
    addTearDown(slow.destroy);
    await post(slow, forged('n2'), length: 20 * 1024 * 1024, sent: 1024);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final second = await Socket.connect('127.0.0.1', f.hub.port);
    await post(second, forged('n3'), length: 100);
    expect(await answer(second), startsWith('HTTP/1.1 429'), reason: 'the first body is still arriving');
  });
}
