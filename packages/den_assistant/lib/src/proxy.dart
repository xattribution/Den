import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'adapters/anthropic.dart';
import 'adapters/gemini.dart';
import 'adapters/ollama.dart';
import 'adapters/openai.dart';
import 'json.dart';
import 'model.dart';
import 'providers.dart';

/// The hub's side of `POST /api/v1/assistant/model`: takes a device's request, already written
/// in the provider's format by its adapter, checks it against the hub's setup, and forwards it
/// with the key the hub keeps. The answer goes back to the device unchanged; [ProxyReply.usage]
/// is for the family's budget. Nothing here keeps or logs content.
class ModelProxy {
  /// A proxy to [provider] with [apiKey], allowing [models].
  ModelProxy({
    required this.provider,
    this.apiKey,
    Uri? baseUrl,
    required Set<String> models,
    http.Client? client,
    this.timeout = const Duration(seconds: 90),
  })  : base = baseUrl ?? provider.defaultBase,
        models = Set.unmodifiable(models),
        _http = client ?? http.Client();

  /// The provider the hub is set up with.
  final ModelProvider provider;

  /// Its key; null for a home model.
  final String? apiKey;

  /// Its address.
  final Uri base;

  /// The model ids devices may ask for.
  final Set<String> models;

  /// How long to wait for the provider.
  final Duration timeout;

  final http.Client _http;

  /// Checks a device's request: the [HubHeaders] it sent ([providerId], [model]) and its [body].
  /// Throws [ProxyRefusal] when it doesn't fit; returns the body's facts for policy otherwise.
  RequestFacts check({required String? providerId, required String? model, required List<int> body}) {
    if (providerId != provider.id) {
      throw ProxyRefusal('The hub runs the assistant with ${provider.speaker}; update this device.');
    }
    if (model == null || !models.contains(model)) {
      throw ProxyRefusal('The hub doesn\'t offer the model "${model ?? ''}".');
    }
    final json = decodeObject(utf8.decode(body, allowMalformed: true));
    if (json.isEmpty) throw const ProxyRefusal('The request wasn\'t JSON.');
    final named = json['model'];
    if (named != null && named != model) throw const ProxyRefusal('The request names a different model.');
    return RequestFacts.of(provider, json);
  }

  /// Forwards [body] for [model] to the provider with the key, after [check]. Throws
  /// [ModelException] when the provider can't be reached.
  Future<ProxyReply> forward({required String model, required List<int> body}) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            provider.endpoint(base, model),
            headers: {'content-type': 'application/json', ...provider.authHeaders(apiKey)},
            body: body,
          )
          .timeout(timeout);
    } on TimeoutException {
      throw ModelException('${provider.speaker} took too long to answer.', kind: ModelFailure.timeout, retry: true);
    } on Object catch (e) {
      throw ModelException('Couldn\'t reach ${provider.speaker}.', kind: ModelFailure.network, retry: true, detail: '$e');
    }
    final usage = response.statusCode == 200
        ? usageFrom(provider, decodeObject(utf8.decode(response.bodyBytes, allowMalformed: true)))
        : null;
    return ProxyReply(
      status: response.statusCode,
      body: response.bodyBytes,
      usage: usage,
      costUsd: usage?.costUsd(modelInfo(provider, model).price),
    );
  }
}

/// Why the hub won't forward a request; the message is for people.
class ProxyRefusal implements Exception {
  /// A refusal explained by [message].
  const ProxyRefusal(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'ProxyRefusal: $message';
}

/// What the provider answered, for the device, and what it cost.
class ProxyReply {
  /// An answer.
  const ProxyReply({required this.status, required this.body, this.usage, this.costUsd});

  /// The provider's HTTP status.
  final int status;

  /// The provider's body, sent to the device unchanged.
  final List<int> body;

  /// Tokens used, when the call succeeded.
  final Usage? usage;

  /// The estimated cost in US dollars, when the call succeeded.
  final double? costUsd;
}

/// What a request asks for, read from its provider-format body, for the hub's policy: a cap on
/// output, and no photos for kids.
class RequestFacts {
  /// Facts.
  const RequestFacts({required this.maxTokens, required this.images, required this.tools});

  /// The output cap the request asks for; 0 when it sets none.
  final int maxTokens;

  /// How many photos it carries.
  final int images;

  /// How many tools it declares.
  final int tools;

  /// The facts of [json], a request body for [provider].
  static RequestFacts of(ModelProvider provider, Map<String, Object?> json) {
    var images = 0;
    switch (provider) {
      case ModelProvider.anthropic:
        for (final m in asList(json['messages'])) {
          for (final block in asList(asMap(m)['content'])) {
            if (asMap(block)['type'] == 'image') images++;
          }
        }
        return RequestFacts(maxTokens: asInt(json['max_tokens']), images: images, tools: asList(json['tools']).length);
      case ModelProvider.openai || ModelProvider.xai:
        for (final item in asList(json['input'])) {
          for (final part in asList(asMap(item)['content'])) {
            if (asMap(part)['type'] == 'input_image') images++;
          }
        }
        return RequestFacts(
          maxTokens: asInt(json['max_output_tokens']),
          images: images,
          tools: asList(json['tools']).length,
        );
      case ModelProvider.gemini:
        for (final content in asList(json['contents'])) {
          for (final part in asList(asMap(content)['parts'])) {
            if (asMap(part).containsKey('inlineData')) images++;
          }
        }
        var tools = 0;
        for (final tool in asList(json['tools'])) {
          tools += asList(asMap(tool)['functionDeclarations']).length;
        }
        return RequestFacts(
          maxTokens: asInt(asMap(json['generationConfig'])['maxOutputTokens']),
          images: images,
          tools: tools,
        );
      case ModelProvider.ollama:
        for (final m in asList(json['messages'])) {
          images += asList(asMap(m)['images']).length;
        }
        return RequestFacts(
          maxTokens: asInt(asMap(json['options'])['num_predict']),
          images: images,
          tools: asList(json['tools']).length,
        );
    }
  }
}

/// The tokens a successful response from [provider] reports.
Usage usageFrom(ModelProvider provider, Map<String, Object?> json) => switch (provider) {
      ModelProvider.anthropic => AnthropicChatModel.usageOf(json),
      ModelProvider.openai || ModelProvider.xai => OpenAIChatModel.usageOf(json),
      ModelProvider.gemini => GeminiChatModel.usageOf(json),
      ModelProvider.ollama => OllamaChatModel.usageOf(json),
    };
