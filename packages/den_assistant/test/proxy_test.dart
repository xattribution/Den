import 'dart:convert';

import 'package:den_assistant/den_assistant.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('a device\'s request goes through the hub to the provider with the hub\'s key', () async {
    // The device: an adapter pointed at the hub.
    final device = Recorder();
    final model = AnthropicChatModel(
      endpoint: ModelEndpoint.hub(Uri.parse('https://hub.local/api/v1/assistant/model')),
      client: device.answer(200, 'anthropic/tool_use.json'),
    );
    await model.respond(sampleRequest(messages: [UserMessage('Look at this', images: [tinyPng])]));
    final sent = device.requests.single;

    // The hub: checks what came in and forwards it.
    final upstream = Recorder();
    final proxy = ModelProxy(
      provider: ModelProvider.anthropic,
      apiKey: 'sk-ant-hub',
      models: {'claude-haiku-5-5', 'claude-sonnet-5-5'},
      client: upstream.answer(200, 'anthropic/tool_use.json'),
    );
    final facts = proxy.check(
      providerId: sent.headers[HubHeaders.provider],
      model: sent.headers[HubHeaders.model],
      body: sent.bodyBytes,
    );
    expect(facts.maxTokens, 1000);
    expect(facts.images, 1);
    expect(facts.tools, 2);

    final reply = await proxy.forward(model: 'claude-haiku-5-5', body: sent.bodyBytes);
    final forwarded = upstream.requests.single;
    expect(forwarded.url.toString(), 'https://api.anthropic.com/v1/messages');
    expect(forwarded.headers['x-api-key'], 'sk-ant-hub');
    expect(forwarded.headers['anthropic-version'], '2023-06-01');
    expect(forwarded.bodyBytes, sent.bodyBytes);
    expect(reply.status, 200);
    expect(utf8.decode(reply.body), fixtureText('anthropic/tool_use.json'));
    expect(reply.usage?.cacheReadTokens, 3880);
    expect(reply.costUsd, closeTo((412 * 0.10 + 96 * 0.50 + 3880 * 0.01) / 1000000, 1e-12));
  });

  test('the hub refuses another provider, a model it doesn\'t offer, or a mismatched body', () {
    final proxy = ModelProxy(provider: ModelProvider.gemini, apiKey: 'k', models: {'gemini-3.5-flash-lite'});
    final body = utf8.encode(jsonEncode(GeminiChatModel(endpoint: const ModelEndpoint.direct()).body(sampleRequest())));
    expect(proxy.check(providerId: 'gemini', model: 'gemini-3.5-flash-lite', body: body).tools, 2);
    expect(() => proxy.check(providerId: 'openai', model: 'gemini-3.5-flash-lite', body: body), throwsA(isA<ProxyRefusal>()));
    expect(() => proxy.check(providerId: 'gemini', model: 'gemini-4-argon', body: body), throwsA(isA<ProxyRefusal>()));
    expect(() => proxy.check(providerId: 'gemini', model: 'gemini-3.5-flash-lite', body: utf8.encode('nope')), throwsA(isA<ProxyRefusal>()));

    final openai = ModelProxy(provider: ModelProvider.openai, apiKey: 'k', models: {'gpt-6-luna', 'gpt-6.1-sol'});
    final named = utf8.encode(jsonEncode(OpenAIChatModel(endpoint: const ModelEndpoint.direct(), model: 'gpt-6.1-sol').body(sampleRequest())));
    expect(() => openai.check(providerId: 'openai', model: 'gpt-6-luna', body: named), throwsA(isA<ProxyRefusal>()));
    expect(openai.check(providerId: 'openai', model: 'gpt-6.1-sol', body: named).maxTokens, 1000);
  });

  test('facts for every provider\'s format', () {
    final request = sampleRequest(messages: [UserMessage('Look', images: [tinyPng])]);
    const endpoint = ModelEndpoint.direct();
    final bodies = {
      ModelProvider.anthropic: AnthropicChatModel(endpoint: endpoint).body(request),
      ModelProvider.openai: OpenAIChatModel(endpoint: endpoint).body(request),
      ModelProvider.xai: OpenAIChatModel.grok(endpoint: endpoint).body(request),
      ModelProvider.gemini: GeminiChatModel(endpoint: endpoint).body(request),
      ModelProvider.ollama: OllamaChatModel(endpoint: endpoint).body(request),
    };
    for (final entry in bodies.entries) {
      final facts = RequestFacts.of(entry.key, entry.value);
      expect(facts.maxTokens, 1000, reason: entry.key.id);
      expect(facts.images, 1, reason: entry.key.id);
      expect(facts.tools, 2, reason: entry.key.id);
    }
  });

  test('every provider has a small default and a bigger model, and says where data goes', () {
    for (final provider in ModelProvider.values) {
      final small = defaultModel(provider);
      final large = defaultModel(provider, size: ModelSize.large);
      expect(small.size, ModelSize.small);
      expect(large.size, ModelSize.large);
      expect(small.model, isNot(large.model));
      expect(chatModelFor(provider, endpoint: const ModelEndpoint.direct()).info.model, small.model);
      expect(chatModelFor(provider, endpoint: const ModelEndpoint.direct(), size: ModelSize.large).info.model, large.model);
    }
    expect(ModelProvider.anthropic.dataGoesTo, 'Anthropic');
    expect(ModelProvider.gemini.dataGoesTo, 'Google');
    expect(ModelProvider.ollama.dataGoesTo, 'home');
    expect(defaultModel(ModelProvider.ollama).price.input, 0);
    final custom = modelInfo(ModelProvider.ollama, 'llama3.2');
    expect(custom.images, isFalse);
    expect(custom.label, 'llama3.2');
  });
}
