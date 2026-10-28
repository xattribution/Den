import '../../../platform/sync/den_network.dart';
import '../../../platform/sync/hub_api.dart';

/// Who runs the AI helper on the family's hub, and what it spent this month, as the hub says
/// (`GET /api/v1/assistant`). The key itself never leaves the hub.
class AssistantSetup {
  const AssistantSetup({
    this.provider,
    this.dataGoesTo,
    this.keySaved = false,
    this.keyFromCapture = false,
    this.baseUrl,
    this.spentCents = 0,
    this.budgetCents = 0,
    this.stopped = false,
  });

  factory AssistantSetup.fromJson(Map<String, Object?> json) {
    final month = json['this_month'] is Map ? (json['this_month']! as Map).cast<String, Object?>() : const <String, Object?>{};
    return AssistantSetup(
      provider: json['provider'] as String?,
      dataGoesTo: json['data_goes_to'] as String?,
      keySaved: json['key_saved'] == true,
      keyFromCapture: json['key_from'] == 'capture',
      baseUrl: json['base_url'] as String?,
      spentCents: (month['spent_cents'] as num?)?.toInt() ?? 0,
      budgetCents: (month['budget_cents'] as num?)?.toInt() ?? 0,
      stopped: month['stopped'] == true,
    );
  }

  /// `anthropic`, `openai`, `gemini`, `xai`, `ollama`; null when nobody is set up.
  final String? provider;

  /// "Anthropic", "OpenAI", "Google", "xAI", or "home".
  final String? dataGoesTo;
  final bool keySaved;

  /// It uses the Claude key saved for reading photos.
  final bool keyFromCapture;

  /// A home model's address.
  final String? baseUrl;
  final int spentCents;
  final int budgetCents;

  /// The month's budget is spent.
  final bool stopped;
}

/// Where the AI helper's setup comes from: the hub, or a fake in tests.
abstract interface class AssistantSource {
  Future<AssistantSetup> status();

  /// Chooses [provider] (null turns it off on the hub and forgets the key), with its [key], the
  /// key saved for reading photos ([useCaptureKey]), or a home model's [baseUrl].
  Future<AssistantSetup> configure({String? provider, String? key, bool useCaptureKey = false, String? baseUrl});
}

/// The hub's `/api/v1/assistant`, signed by this device; changing it takes a parent's own phone.
class AssistantHub implements AssistantSource {
  AssistantHub(DenNetwork network) : _api = HubApi(network);

  final HubApi _api;

  static const _old = "The family's hub doesn't run the AI helper yet. Update the hub, then try again.";

  @override
  Future<AssistantSetup> status() async => AssistantSetup.fromJson(await _api.send('GET', '/api/v1/assistant', missing: _old));

  @override
  Future<AssistantSetup> configure({String? provider, String? key, bool useCaptureKey = false, String? baseUrl}) async =>
      AssistantSetup.fromJson(await _api.send(
        'PUT',
        '/api/v1/assistant',
        body: {
          'provider': provider,
          if (key != null && key.isNotEmpty) 'key': key,
          if (useCaptureKey) 'use_capture_key': true,
          if (baseUrl != null && baseUrl.isNotEmpty) 'base_url': baseUrl,
        },
        missing: _old,
      ));
}

/// The companies a family can choose to run the AI helper, in the words Settings uses.
const Map<String, String> assistantProviders = {
  'anthropic': 'Claude, by Anthropic',
  'openai': 'ChatGPT, by OpenAI',
  'gemini': 'Gemini, by Google',
  'xai': 'Grok, by xAI',
  'ollama': 'A computer at home',
};

/// What each is called in a sentence: "Claude runs it."
const Map<String, String> assistantNames = {
  'anthropic': 'Claude',
  'openai': 'ChatGPT',
  'gemini': 'Gemini',
  'xai': 'Grok',
  'ollama': 'A computer at home',
};

/// Who receives what's asked, for the privacy words: "Anthropic", or null for a computer at home.
String? assistantCompany(String? provider) => switch (provider) {
      'anthropic' => 'Anthropic',
      'openai' => 'OpenAI',
      'gemini' => 'Google',
      'xai' => 'xAI',
      _ => null,
    };

/// "$1.20", "$5".
String dollars(int cents) => cents % 100 == 0 ? '\$${cents ~/ 100}' : '\$${(cents / 100).toStringAsFixed(2)}';
