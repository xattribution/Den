/// Where what a person types goes while the assistant answers.
enum DataPlace {
  /// A company's servers.
  provider,

  /// A computer in the family's home.
  home,
}

/// A company or program that runs the model.
enum ModelProvider {
  /// Claude, through the Messages API.
  anthropic('anthropic', 'Anthropic', 'Claude', 'https://api.anthropic.com'),

  /// OpenAI, through the Responses API.
  openai('openai', 'OpenAI', 'OpenAI', 'https://api.openai.com/v1'),

  /// Google Gemini, through `generateContent`.
  gemini('gemini', 'Google', 'Gemini', 'https://generativelanguage.googleapis.com/v1beta'),

  /// xAI Grok, through its OpenAI-compatible Responses API.
  xai('xai', 'xAI', 'Grok', 'https://api.x.ai/v1'),

  /// A model the family runs at home with Ollama, usually on the hub's computer.
  ollama('ollama', 'a computer at home', 'The home model', 'http://localhost:11434');

  const ModelProvider(this.id, this.company, this.speaker, this.baseUrl);

  /// Stable id: `anthropic`, `openai`, `gemini`, `xai`, `ollama`.
  final String id;

  /// Who receives the data, for the privacy text.
  final String company;

  /// What people call it in messages ("Claude is busy right now").
  final String speaker;

  /// The API's base address.
  final String baseUrl;

  /// Whether the data leaves the house.
  DataPlace get place => this == ModelProvider.ollama ? DataPlace.home : DataPlace.provider;

  /// "Anthropic", "OpenAI", "Google", "xAI", or "home".
  String get dataGoesTo => place == DataPlace.home ? 'home' : company;

  /// [baseUrl] as a URI.
  Uri get defaultBase => Uri.parse(baseUrl);

  /// The address a request for [model] goes to, under [base].
  Uri endpoint(Uri base, String model) => joinPath(base, switch (this) {
        ModelProvider.anthropic => '/v1/messages',
        ModelProvider.openai || ModelProvider.xai => '/responses',
        ModelProvider.gemini => '/models/${Uri.encodeComponent(model)}:generateContent',
        ModelProvider.ollama => '/api/chat',
      });

  /// The headers that carry [apiKey] (and the API version) to this provider.
  Map<String, String> authHeaders(String? apiKey) {
    final key = apiKey?.trim() ?? '';
    return switch (this) {
      ModelProvider.anthropic => {'anthropic-version': '2023-06-01', if (key.isNotEmpty) 'x-api-key': key},
      ModelProvider.gemini => {if (key.isNotEmpty) 'x-goog-api-key': key},
      ModelProvider.openai || ModelProvider.xai || ModelProvider.ollama => {
          if (key.isNotEmpty) 'authorization': 'Bearer $key',
        },
    };
  }

  /// The provider with [id], or null.
  static ModelProvider? byId(String? id) {
    for (final p in values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// [base] with [path] appended (unlike `Uri.resolve`, which drops the base's last segment).
Uri joinPath(Uri base, String path) {
  final text = base.toString();
  final trimmed = text.endsWith('/') ? text.substring(0, text.length - 1) : text;
  return Uri.parse('$trimmed$path');
}

/// The default model, or the bigger one for planning.
enum ModelSize {
  /// The provider's small, fast model: the default.
  small,

  /// "Use the bigger model for planning".
  large,
}

/// US dollars per million tokens.
class ModelPrice {
  /// Prices per million tokens.
  const ModelPrice({required this.input, required this.output, required this.cachedInput, required this.cacheWrite});

  /// A model at home.
  static const free = ModelPrice(input: 0, output: 0, cachedInput: 0, cacheWrite: 0);

  /// Input that wasn't read from a cache.
  final double input;

  /// Output, thinking included.
  final double output;

  /// Input read from the provider's cache.
  final double cachedInput;

  /// Input written to the provider's cache (Anthropic's 5-minute writes, OpenAI's 30-minute
  /// writes; the plain input price where writes cost nothing extra).
  final double cacheWrite;
}

/// What a model is, where the data goes, and what it costs.
class ModelInfo {
  /// A model's facts.
  const ModelInfo({
    required this.provider,
    required this.model,
    required this.label,
    required this.size,
    required this.images,
    required this.contextTokens,
    required this.price,
  });

  /// Who runs it.
  final ModelProvider provider;

  /// The API's model id.
  final String model;

  /// What Settings shows.
  final String label;

  /// Small (default) or large.
  final ModelSize size;

  /// Whether it can look at photos.
  final bool images;

  /// The context window, in tokens.
  final int contextTokens;

  /// For cost estimates.
  final ModelPrice price;

  /// "Anthropic", "OpenAI", "Google", "xAI", or "home".
  String get dataGoesTo => provider.dataGoesTo;

  /// Whether nothing leaves the house.
  bool get staysHome => provider.place == DataPlace.home;
}

/// Every model Den offers, two per provider: the small default and the bigger one for planning.
/// Update ids and prices here when providers change them; nothing else names a model.
///
/// Checked against the providers' docs on 2026-10-28:
/// - Anthropic: platform.claude.com/docs/en/about-claude/models/overview and .../pricing. Haiku 5.5
///   costs more for prompts over 100k tokens, which Den never sends.
/// - OpenAI: developers.openai.com/api/docs/models and .../pricing (cache writes at the 30-minute rate).
/// - Google: ai.google.dev/gemini-api/docs/models and .../pricing. Gemini 3.8 Flash's price doubles
///   on 2027-01-01. Context sizes aren't listed per model; 1M is assumed.
/// - xAI: docs.x.ai/developers/models. No model is labelled small or fast; the non-reasoning 4.20
///   model is the cheapest general one. Image input isn't documented per model, so it's off.
/// - Ollama: ollama.com/library/qwen3 and /qwen3.8; the tool-calling docs use qwen3.
const List<ModelInfo> modelTable = [
  ModelInfo(
    provider: ModelProvider.anthropic,
    model: 'claude-haiku-5-5',
    label: 'Claude Haiku 5.5',
    size: ModelSize.small,
    images: true,
    contextTokens: 1000000,
    price: ModelPrice(input: 0.10, output: 0.50, cachedInput: 0.01, cacheWrite: 0.125),
  ),
  ModelInfo(
    provider: ModelProvider.anthropic,
    model: 'claude-sonnet-5-5',
    label: 'Claude Sonnet 5.5',
    size: ModelSize.large,
    images: true,
    contextTokens: 1000000,
    price: ModelPrice(input: 2.00, output: 10.00, cachedInput: 0.10, cacheWrite: 2.50),
  ),
  ModelInfo(
    provider: ModelProvider.openai,
    model: 'gpt-6-luna',
    label: 'GPT-6 Luna',
    size: ModelSize.small,
    images: true,
    contextTokens: 1050000,
    price: ModelPrice(input: 0.10, output: 0.50, cachedInput: 0.01, cacheWrite: 0.125),
  ),
  ModelInfo(
    provider: ModelProvider.openai,
    model: 'gpt-6.1-sol',
    label: 'GPT-6.1 Sol',
    size: ModelSize.large,
    images: true,
    contextTokens: 1050000,
    price: ModelPrice(input: 2.00, output: 10.00, cachedInput: 0.10, cacheWrite: 2.50),
  ),
  ModelInfo(
    provider: ModelProvider.gemini,
    model: 'gemini-3.5-flash-lite',
    label: 'Gemini 3.5 Flash-Lite',
    size: ModelSize.small,
    images: true,
    contextTokens: 1048576,
    price: ModelPrice(input: 0.30, output: 2.50, cachedInput: 0.03, cacheWrite: 0.30),
  ),
  ModelInfo(
    provider: ModelProvider.gemini,
    model: 'gemini-3.8-flash',
    label: 'Gemini 3.8 Flash',
    size: ModelSize.large,
    images: true,
    contextTokens: 1048576,
    price: ModelPrice(input: 0.75, output: 3.75, cachedInput: 0.075, cacheWrite: 0.75),
  ),
  ModelInfo(
    provider: ModelProvider.xai,
    model: 'grok-4.20-0309-non-reasoning',
    label: 'Grok 4.20',
    size: ModelSize.small,
    images: false,
    contextTokens: 1000000,
    price: ModelPrice(input: 1.25, output: 2.50, cachedInput: 0.20, cacheWrite: 1.25),
  ),
  ModelInfo(
    provider: ModelProvider.xai,
    model: 'grok-4.7',
    label: 'Grok 4.7',
    size: ModelSize.large,
    images: false,
    contextTokens: 500000,
    price: ModelPrice(input: 2.00, output: 6.00, cachedInput: 0.50, cacheWrite: 2.00),
  ),
  ModelInfo(
    provider: ModelProvider.ollama,
    model: 'qwen3:8b',
    label: 'Qwen3 8B',
    size: ModelSize.small,
    images: false,
    contextTokens: 40960,
    price: ModelPrice.free,
  ),
  ModelInfo(
    provider: ModelProvider.ollama,
    model: 'qwen3.8:27b',
    label: 'Qwen3.8 27B',
    size: ModelSize.large,
    images: true,
    contextTokens: 262144,
    price: ModelPrice.free,
  ),
];

/// [provider]'s default model, or its bigger one.
ModelInfo defaultModel(ModelProvider provider, {ModelSize size = ModelSize.small}) =>
    modelTable.firstWhere((m) => m.provider == provider && m.size == size);

/// The facts for [model] at [provider]. A model that isn't in [modelTable] (a parent typed it, or
/// a home model) is priced like the provider's bigger model, a safe overestimate, and gets no photos.
ModelInfo modelInfo(ModelProvider provider, String model) {
  for (final m in modelTable) {
    if (m.provider == provider && m.model == model) return m;
  }
  final like = defaultModel(provider, size: ModelSize.large);
  return ModelInfo(
    provider: provider,
    model: model,
    label: model,
    size: ModelSize.large,
    images: false,
    contextTokens: provider == ModelProvider.ollama ? 8192 : like.contextTokens,
    price: like.price,
  );
}
