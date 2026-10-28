import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    dir = await Directory.systemTemp.createTemp('den-capture-hub');
    anthropic = FakeAnthropic(claudeFixture('claude_email.json'));
    f = await HubFixture.start(
      dataDir: dir.path,
      configure: (base) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        dataDir: dir.path,
        log: HubLog(level: LogLevel.error, sink: (_) {}),
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
}
