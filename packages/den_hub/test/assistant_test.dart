@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_assistant/den_assistant.dart' show ModelProvider;
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fixture.dart';
import 'support/test.dart';

/// The in-app assistant's side on the hub: a parent sets the provider and key, devices send
/// their model requests through the hub, which holds them to the family's rules and budget.
void main() {
  late HubFixture f;
  late Den mayaPhone;
  late Den leoTablet;
  final logged = <String>[];
  final sent = <http.Request>[];
  var usage = <String, Object?>{'input_tokens': 1000, 'output_tokens': 200};
  var down = false;
  const key = 'sk-ant-hub-test-123';
  const said = 'What is on today for the family';

  setUpAll(() async {
    f = await HubFixture.start(
      configure: (c) => HubConfig(
        port: 0,
        host: InternetAddress.loopbackIPv4,
        mdns: false,
        log: HubLog(level: LogLevel.debug, sink: logged.add),
        // Stands in for Anthropic's Messages API.
        httpClient: MockClient((r) async {
          if (down) throw const SocketException('unreachable');
          sent.add(r);
          return http.Response(
            jsonEncode({
              'id': 'msg_1',
              'type': 'message',
              'role': 'assistant',
              'model': 'claude-haiku-5-5',
              'content': [
                {'type': 'text', 'text': 'Soccer at 5.'},
              ],
              'stop_reason': 'end_turn',
              'usage': usage,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
    );
    Future<Den> device(String name, String member) async {
      final d = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());
      await d.requestJoin(familyId: f.phone.familyId!, founderPubkey: f.phone.founderPubkey!, deviceName: name, kind: DeviceKind.phone);
      await f.phone.ingest(d.changesSince(const {}));
      await f.phone.approveDevice(d.deviceId, member: member);
      await d.ingest(f.phone.changesSince(const {}));
      return d;
    }

    mayaPhone = await device('Maya phone', f.id('Maya'));
    leoTablet = await device('Leo tablet', f.id('Leo'));
    await f.toHub();
  });
  tearDownAll(() async {
    await mayaPhone.close();
    await leoTablet.close();
    await f.stop();
  });

  Future<ApiResult> signed(Den device, String method, String path, {Object? body, Map<String, String> headers = const {}}) async {
    final text = body == null ? null : (body is String ? body : jsonEncode(body));
    final sig = await DeviceRequest.sign(
      keys: device.keys,
      method: method,
      url: f.base.resolve(path),
      body: text == null ? const [] : utf8.encode(text),
      hub: f.hubDen.deviceId,
      actorId: device.actor?.id,
    );
    return f.call(method, path, body: text, headers: {...sig, ...headers});
  }

  Map<String, Object?> ask(String text, {int maxTokens = 1024, bool photo = false, bool toolResult = false, String model = 'claude-haiku-5-5'}) => {
        'model': model,
        'max_tokens': maxTokens,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': text},
              if (photo)
                {
                  'type': 'image',
                  'source': {'type': 'base64', 'media_type': 'image/png', 'data': 'iVBORw0KGgo='},
                },
            ],
          },
          if (toolResult) ...[
            {
              'role': 'assistant',
              'content': [
                {'type': 'tool_use', 'id': 't1', 'name': 'get_overview', 'input': <String, Object?>{}},
              ],
            },
            {
              'role': 'user',
              'content': [
                {'type': 'tool_result', 'tool_use_id': 't1', 'content': 'Soccer at 5'},
              ],
            },
          ],
        ],
      };

  Future<ApiResult> model(Den device, Map<String, Object?> body, {String provider = 'anthropic', String? model}) =>
      signed(device, 'POST', '/api/v1/assistant/model',
          body: body, headers: {'x-den-provider': provider, 'x-den-model': model ?? body['model'] as String});

  Future<void> policy(AssistantPolicy p) async {
    await f.phone.updateFamily({'assistant': p.toJson()});
    await f.toHub();
  }

  test('off by default, and only a parent\'s own phone chooses who runs it', () async {
    final status = await signed(f.phone, 'GET', '/api/v1/assistant');
    expect(status.status, 200, reason: status.text);
    expect(status.body['provider'], isNull);
    expect(status.body['key_saved'], isFalse);
    expect((status.body['policy'] as Map)['enabled'], isFalse);
    final off = await model(f.phone, ask(said));
    expect(off.status, 403);
    expect(off.error['code'], 'assistant_off');
    expect((await f.call('PUT', '/api/v1/assistant', body: {'provider': 'anthropic', 'key': key})).status, 401);
    final kid = await signed(mayaPhone, 'PUT', '/api/v1/assistant', body: {'provider': 'anthropic', 'key': key});
    expect(kid.status, 403);
    expect(sent, isEmpty);
  });

  test('a parent sets the provider and key, which no answer shows', () async {
    final bad = await signed(f.phone, 'PUT', '/api/v1/assistant', body: {'provider': 'anthropic', 'key': 'not a key'});
    expect(bad.status, 400);
    final noCapture = await signed(f.phone, 'PUT', '/api/v1/assistant', body: {'provider': 'anthropic', 'use_capture_key': true});
    expect(noCapture.status, 400, reason: 'there is no capture key yet');
    final set = await signed(f.phone, 'PUT', '/api/v1/assistant', body: {'provider': 'anthropic', 'key': key});
    expect(set.status, 200, reason: set.text);
    expect(set.body['provider'], 'anthropic');
    expect(set.body['speaker'], 'Claude');
    expect(set.body['key_saved'], isTrue);
    expect(set.body['key_from'], 'own');
    expect((set.body['models'] as List).map((m) => (m as Map)['model']), contains('claude-haiku-5-5'));
    expect(set.text, isNot(contains(key)));
    final seen = await signed(mayaPhone, 'GET', '/api/v1/assistant');
    expect(seen.text, isNot(contains(key)));
    expect((seen.body['you'] as Map)['allowed'], isFalse, reason: 'still off in the family\'s settings');
    expect(f.hub.assistant.provider, ModelProvider.anthropic);
  });

  test('a parent\'s request goes on with the hub\'s key; the device never holds it', () async {
    await policy(AssistantPolicy(enabled: true, members: {f.id('Maya'), f.id('Leo')}, kidDailyLimit: 2, budgetCents: 500));
    final r = await model(f.phone, ask(said));
    expect(r.status, 200, reason: r.text);
    expect(((r.body['content'] as List).single as Map)['text'], 'Soccer at 5.');
    expect(r.headers['x-den-budget-cents'], '500');
    final out = sent.last;
    expect(out.url.toString(), 'https://api.anthropic.com/v1/messages');
    expect(out.headers['x-api-key'], key);
    expect(jsonDecode(out.body), ask(said), reason: 'the body goes on unchanged');

    final otherModel = await model(f.phone, ask(said, model: 'claude-opus-9'));
    expect(otherModel.status, 403);
    expect(otherModel.error['code'], 'refused');
    final otherProvider = await model(f.phone, ask(said), provider: 'openai');
    expect(otherProvider.status, 403);
    final long = await model(f.phone, ask(said, maxTokens: 100000));
    expect(long.error['code'], 'too_long');
    final status = await signed(f.phone, 'GET', '/api/v1/assistant');
    expect((status.body['this_month'] as Map)['spent_cents'], greaterThan(0));
  });

  test('when the provider can\'t be reached the device hears so', () async {
    down = true;
    try {
      final r = await model(f.phone, ask(said));
      expect(r.status, 502);
      expect(r.error['code'], 'provider_unreachable');
    } finally {
      down = false;
    }
  });

  test('kids: only the ones a parent picked, never a little one, no photos, a few questions a day', () async {
    final leo = await model(leoTablet, ask(said));
    expect(leo.status, 403, reason: 'Leo is little, whatever the list says');
    expect(leo.error['code'], 'not_allowed');

    final photo = await model(mayaPhone, ask(said, photo: true));
    expect(photo.status, 403);
    expect(photo.error['code'], 'no_photos');
    final long = await model(mayaPhone, ask(said, maxTokens: 4096));
    expect(long.error['code'], 'too_long', reason: 'kids\' answers are shorter');

    expect((await model(mayaPhone, ask(said))).status, 200);
    expect((await model(mayaPhone, ask(said, toolResult: true))).status, 200, reason: 'a tool\'s answer isn\'t a new question');
    expect((await model(mayaPhone, ask('And tomorrow?'))).status, 200);
    final limited = await model(mayaPhone, ask('And the day after?'));
    expect(limited.status, 429);
    expect(limited.error['code'], 'daily_limit');
    expect(limited.error['message'], contains('Maya'));
    final you = (await signed(mayaPhone, 'GET', '/api/v1/assistant')).body['you'] as Map;
    expect(you['used_today'], 2);
    expect(you['daily_limit'], 2);
    expect((await model(f.phone, ask(said))).status, 200, reason: 'parents have no daily limit');
  });

  test('the month\'s budget warns at 80% and stops at 100%', () async {
    final spentSoFar = (((await signed(f.phone, 'GET', '/api/v1/assistant')).body['this_month'] as Map)['spent_cents']) as int;
    // Each request below costs 0.8 cents with Claude Haiku's prices.
    usage = {'input_tokens': 40000, 'output_tokens': 8000};
    await policy(AssistantPolicy(enabled: true, members: {f.id('Maya')}, budgetCents: spentSoFar + 2));
    var ok = 0;
    ApiResult last;
    do {
      last = await model(f.phone, ask(said));
      if (last.status == 200) ok++;
    } while (last.status == 200 && ok < 10);
    expect(last.status, 402);
    expect(last.error['code'], 'budget_spent');
    expect(ok, inInclusiveRange(2, 4));
    final status = (await signed(f.phone, 'GET', '/api/v1/assistant')).body['this_month'] as Map;
    expect(status['warn'], isTrue);
    expect(status['stopped'], isTrue);
    expect(logged.any((l) => l.contains('of this month\'s budget')), isTrue, reason: 'parents are warned at 80%');
    await policy(AssistantPolicy(enabled: true, members: {f.id('Maya')}, budgetCents: 100000));
    expect((await model(f.phone, ask(said))).status, 200, reason: 'a parent raising the budget lets it go on');
  });

  test('"use the capture key" reads the Claude key saved for captures, and nothing said is logged', () async {
    const captureKey = 'sk-ant-capture-test-456';
    final reader = await signed(f.phone, 'PUT', '/api/v1/capture/reader', body: {'kind': 'claude', 'key': captureKey});
    expect(reader.status, 200, reason: reader.text);
    final set = await signed(f.phone, 'PUT', '/api/v1/assistant', body: {'provider': 'anthropic', 'use_capture_key': true});
    expect(set.status, 200, reason: set.text);
    expect(set.body['key_from'], 'capture');
    expect((await model(f.phone, ask(said))).status, 200);
    expect(sent.last.headers['x-api-key'], captureKey);

    final off = await signed(f.phone, 'PUT', '/api/v1/assistant', body: {'provider': null});
    expect(off.body['provider'], isNull);
    final none = await model(f.phone, ask(said));
    expect(none.error['code'], 'not_set_up');

    for (final line in logged) {
      expect(line, isNot(contains(said)), reason: 'no content in the log');
      expect(line, isNot(contains('sk-ant-')), reason: 'no key in the log');
    }
  });

  test('a new question, not a tool\'s answer, is what counts, for every provider\'s format', () {
    expect(HubAssistant.newTurn(ModelProvider.anthropic, ask('hi')), isTrue);
    expect(HubAssistant.newTurn(ModelProvider.anthropic, ask('hi', toolResult: true)), isFalse);
    expect(
        HubAssistant.newTurn(ModelProvider.openai, {
          'input': [
            {'role': 'user', 'content': 'hi'},
          ],
        }),
        isTrue);
    expect(
        HubAssistant.newTurn(ModelProvider.xai, {
          'input': [
            {'type': 'function_call_output', 'call_id': 'c', 'output': '{}'},
          ],
        }),
        isFalse);
    expect(
        HubAssistant.newTurn(ModelProvider.gemini, {
          'contents': [
            {
              'role': 'user',
              'parts': [
                {
                  'functionResponse': {'name': 'x', 'response': <String, Object?>{}},
                },
              ],
            },
          ],
        }),
        isFalse);
    expect(
        HubAssistant.newTurn(ModelProvider.ollama, {
          'messages': [
            {'role': 'tool', 'content': '{}'},
          ],
        }),
        isFalse);
    expect(
        HubAssistant.newTurn(ModelProvider.ollama, {
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
        }),
        isTrue);
  });
}
