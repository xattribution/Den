import 'package:http/http.dart' as http;

import '../endpoint.dart';
import '../model.dart';
import '../providers.dart';
import 'anthropic.dart';
import 'gemini.dart';
import 'ollama.dart';
import 'openai.dart';

/// The adapter for [provider] through [endpoint], with [model] or the provider's model of [size].
ChatModel chatModelFor(
  ModelProvider provider, {
  required ModelEndpoint endpoint,
  String? model,
  ModelSize size = ModelSize.small,
  http.Client? client,
}) {
  final id = model ?? defaultModel(provider, size: size).model;
  return switch (provider) {
    ModelProvider.anthropic => AnthropicChatModel(endpoint: endpoint, model: id, client: client),
    ModelProvider.openai => OpenAIChatModel(endpoint: endpoint, model: id, client: client),
    ModelProvider.xai => OpenAIChatModel.grok(endpoint: endpoint, model: id, client: client),
    ModelProvider.gemini => GeminiChatModel(endpoint: endpoint, model: id, client: client),
    ModelProvider.ollama => OllamaChatModel(endpoint: endpoint, model: id, client: client),
  };
}
