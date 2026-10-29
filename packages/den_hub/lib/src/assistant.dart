import 'dart:convert';
import 'dart:io';

import 'package:den_assistant/den_assistant.dart'
    show ModelException, ModelInfo, ModelProvider, ModelProxy, ModelSize, ProxyRefusal, RequestFacts, defaultModel, modelInfo;
import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import 'context.dart';
import 'device_auth.dart';
import 'http_util.dart';
import 'setup.dart' show restrictToOwner;
import 'usage.dart';

/// The in-app assistant's side on the hub (`/api/v1/assistant`).
///
/// A parent chooses, from their own phone, which provider runs the assistant and gives the hub
/// its key (or lets it use the key already saved for reading captures with Claude). Every device
/// in the family then sends its model requests, written in the provider's own format by
/// den_assistant's adapters, to `/api/v1/assistant/model`, signed with the device's key. The hub
/// checks each against the family's rules (`family.assistant`: who may use it, a kid's daily
/// limit, no photos for kids, the month's budget) and den_assistant's `ModelProxy` (the
/// provider, the models offered, an output cap), forwards it with the key, and counts what it
/// cost ([AiUsage], which captures the hub reads count against too). Phones and the web app
/// never hold the key.
///
/// The key lives in `<data>/hub/assistant.json`, readable by its owner only, never in the
/// family's log or in an answer. The hub keeps no conversation and logs no content: only that
/// the setup changed, and when the month's budget runs low. It is off until a parent turns it
/// on in the family's settings and sets a provider here.
class HubAssistant {
  /// The endpoints for [hub], checking signatures with [auth] and counting in [usage].
  HubAssistant(this.hub, this.auth, this.usage);

  /// Shared hub context.
  final HubContext hub;

  /// Checks the signed requests.
  final DeviceAuth auth;

  /// The family's AI budget and kids' days, shared with captures.
  final AiUsage usage;

  /// Largest model request: a conversation and a few photos.
  static const int maxBody = 12 * 1024 * 1024;

  /// The most output a request may ask for; a kid's requests get [kidMaxOutput].
  static const int maxOutput = 8192, kidMaxOutput = 2048;

  /// Model requests forwarded at once.
  static const int maxForwarding = 6;

  static const String _doc = 'assistant';

  int _forwarding = 0;

  /// Adds the routes.
  void register(Routes routes) {
    routes
      ..add('GET', '/api/v1/assistant', (r, _) => status(r))
      ..add('PUT', '/api/v1/assistant', (r, _) => configure(r))
      ..add('POST', '/api/v1/assistant/model', (r, _) => model(r));
  }

  Map<String, Object?> get _saved => hub.state.read(_doc);

  /// The provider the hub runs the assistant with, or null.
  ModelProvider? get provider => ModelProvider.byId(_saved['provider'] as String?);

  /// The models devices may ask for.
  List<String> get models {
    final p = provider;
    if (p == null) return const [];
    final saved = _saved['models'];
    if (saved is List && saved.isNotEmpty) return [...saved.whereType<String>()];
    return [defaultModel(p).model, defaultModel(p, size: ModelSize.large).model];
  }

  /// The key to send: the hub's own for the assistant, or the capture reader's Claude key.
  String? get _key {
    final s = _saved;
    if (s['key_from'] == 'capture') {
      final capture = hub.state.read('capture');
      final key = capture['kind'] == 'claude' ? capture['key'] : null;
      return key is String && key.isNotEmpty ? key : null;
    }
    final key = s['key'];
    return key is String && key.isNotEmpty ? key : null;
  }

  Uri? get _base {
    final raw = _saved['base_url'];
    return raw is String ? Uri.tryParse(raw) : null;
  }

  AssistantPolicy get _policy => usage.policy;

  /// The month's spending, the assistant's and the captures' the hub's reader read.
  Map<String, Object?> _monthJson() => usage.monthJson(
        free: provider == ModelProvider.ollama,
        captureFree: hub.state.read('capture')['kind'] != 'claude',
      );

  Map<String, Object?> _modelJson(ModelInfo m) =>
      {'model': m.model, 'label': m.label, 'size': m.size.name, 'images': m.images, 'context_tokens': m.contextTokens};

  /// What a device sees: the provider and models, whether a key is saved (never the key), the
  /// family's rules, what [actor] has used today (a kid's questions and the captures the hub
  /// read for them count together), and the month's spending, captures included.
  Map<String, Object?> describe(Member? actor) {
    final p = provider;
    final policy = _policy;
    return {
      'provider': p?.id,
      if (p != null) 'speaker': p.speaker,
      if (p != null) 'data_goes_to': p.dataGoesTo,
      'models': [if (p != null) for (final m in models) _modelJson(modelInfo(p, m))],
      'key_saved': p == ModelProvider.ollama || _key != null,
      'key_from': p == null ? null : (_saved['key_from'] as String? ?? 'own'),
      if (p == ModelProvider.ollama) 'base_url': (_base ?? p!.defaultBase).toString(),
      'policy': policy.toJson(),
      if (actor != null)
        'you': {
          'allowed': p != null && policy.allows(actor),
          if (actor.isKid) 'used_today': usage.usedToday(actor.id),
          if (actor.isKid) 'captures_today': usage.capturesToday(actor.id),
          if (actor.isKid) 'daily_limit': policy.kidDailyLimit,
        },
      'this_month': _monthJson(),
    };
  }

  /// `GET /api/v1/assistant`, for any device in the family.
  Future<Response> status(Request request) async {
    final c = await auth.check(request);
    return jsonResponse(describe(c.actor));
  }

  /// `PUT /api/v1/assistant` `{"provider": "anthropic", "key": "sk-ant-...", "models": [...]}`,
  /// from a parent's own phone: which provider runs the assistant and its key.
  /// `"use_capture_key": true` uses the Claude key saved for reading captures (kept there, read
  /// when needed); `"provider": null` turns it off on the hub and forgets the key. A home model
  /// (`ollama`) takes `"base_url"` instead of a key.
  Future<Response> configure(Request request) async {
    final signed = await auth.withBody(request, limit: 64 * 1024);
    final c = DeviceAuth.parentOf(signed.check, message: 'Only a parent\'s own phone can choose who runs the assistant.');
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(signed.body));
    } on FormatException {
      throw ApiError.invalid('The body must be a JSON object.');
    }
    if (json is! Map) throw ApiError.invalid('The body must be a JSON object.');
    final rawProvider = json['provider'];
    if (rawProvider == null || rawProvider == 'none') {
      await hub.state.save(_doc, {});
      _restrict();
      hub.log.info('${c.actor!.name} turned the assistant off on the hub');
      return jsonResponse(describe(c.actor));
    }
    final p = rawProvider is String ? ModelProvider.byId(rawProvider) : null;
    if (p == null) {
      throw ApiError.invalid('"provider" must be one of ${[for (final x in ModelProvider.values) x.id].join(', ')}, or null.',
          field: 'provider');
    }
    final before = _saved;
    final next = <String, Object?>{'provider': p.id};
    final key = json['key'];
    final useCapture = json['use_capture_key'] == true;
    if (key != null) {
      if (key is! String || key.trim().isEmpty || key.trim().length > 300 || key.trim().contains(RegExp(r'\s'))) {
        throw ApiError.invalid('"key" must be the provider\'s API key.', field: 'key');
      }
      if (p == ModelProvider.anthropic && !key.trim().startsWith('sk-ant-')) {
        throw ApiError.invalid('That doesn\'t look like a Claude API key. Keys start with sk-ant-.', field: 'key');
      }
      next['key'] = key.trim();
      next['key_from'] = 'own';
    } else if (useCapture) {
      if (p != ModelProvider.anthropic) {
        throw ApiError.invalid('The capture key is a Claude key; it only works with "anthropic".', field: 'use_capture_key');
      }
      final capture = hub.state.read('capture');
      if (capture['kind'] != 'claude' || capture['key'] is! String) {
        throw ApiError.invalid('The hub has no Claude key saved for reading captures.', field: 'use_capture_key');
      }
      next['key_from'] = 'capture';
    } else if (before['provider'] == p.id && (before['key'] is String || before['key_from'] == 'capture')) {
      if (before['key'] is String) next['key'] = before['key'];
      next['key_from'] = before['key_from'] ?? 'own';
    } else if (p != ModelProvider.ollama) {
      throw ApiError.invalid('${p.speaker} needs an API key.', field: 'key');
    }
    final wanted = json['models'];
    if (wanted != null) {
      if (wanted is! List ||
          wanted.isEmpty ||
          wanted.length > 6 ||
          wanted.any((m) => m is! String || m.trim().isEmpty || m.length > 100)) {
        throw ApiError.invalid('"models" must list the model ids devices may use.', field: 'models');
      }
      next['models'] = [for (final m in wanted) (m as String).trim()];
    } else if (before['provider'] == p.id && before['models'] is List) {
      next['models'] = before['models'];
    }
    final base = json['base_url'];
    if (base != null) {
      final u = base is String ? Uri.tryParse(base.trim()) : null;
      if (p != ModelProvider.ollama || u == null || !(u.isScheme('http') || u.isScheme('https')) || u.host.isEmpty) {
        throw ApiError.invalid('"base_url" is the home model\'s address, like http://192.168.1.20:11434.', field: 'base_url');
      }
      next['base_url'] = u.toString();
    } else if (before['provider'] == p.id && before['base_url'] is String) {
      next['base_url'] = before['base_url'];
    }
    await hub.state.save(_doc, next);
    _restrict();
    hub.log.info('${c.actor!.name} set the assistant to run with ${p.speaker}');
    return jsonResponse(describe(c.actor));
  }

  void _restrict() {
    final dir = hub.config.dataDir;
    if (dir != null) restrictToOwner('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}$_doc.json');
  }

  /// `POST /api/v1/assistant/model`: one model request from a device, in the provider's format,
  /// with `x-den-provider` and `x-den-model`. Answers the provider's own response, or the hub's
  /// refusal: `403` (off, not for this person, not set up, a model or a photo the hub won't
  /// send), `402` (the month's budget is spent), `429` (a kid's day is used up, or the hub is
  /// busy), `502` (the provider couldn't be reached).
  Future<Response> model(Request request) async {
    final bytes = await _body(request);
    final c = await auth.verify(request, bytes);
    final actor = c.actor;
    if (actor == null) throw ApiError(403, 'not_signed_in', 'Sign in on this screen to use the assistant.');
    final policy = _policy;
    if (!policy.enabled) {
      throw ApiError(403, 'assistant_off', 'The assistant is off. A parent can turn it on in Settings.');
    }
    if (!policy.allows(actor)) {
      throw ApiError(403, 'not_allowed', 'The assistant isn\'t on for ${actor.name}. A parent can turn it on for them in Settings.');
    }
    final p = provider;
    if (p == null) {
      throw ApiError(403, 'not_set_up', 'A parent needs to choose who runs the assistant on the hub, in Settings.');
    }
    final key = _key;
    if (key == null && p != ModelProvider.ollama) {
      throw ApiError(403, 'no_key', 'The hub has no key for ${p.speaker}. A parent can add one in Settings.');
    }
    final proxy = ModelProxy(provider: p, apiKey: key, baseUrl: _base, models: models.toSet(), client: hub.http);
    final model = request.headers['x-den-model'];
    final RequestFacts facts;
    try {
      facts = proxy.check(providerId: request.headers['x-den-provider'], model: model, body: bytes);
    } on ProxyRefusal catch (e) {
      throw ApiError(403, 'refused', e.message);
    }
    final kid = actor.isKid;
    final cap = kid ? kidMaxOutput : maxOutput;
    if (facts.maxTokens <= 0 || facts.maxTokens > cap) {
      throw ApiError(403, 'too_long', 'The hub sends requests for at most $cap tokens of answer.');
    }
    if (kid && facts.images > 0) throw ApiError(403, 'no_photos', 'Photos aren\'t part of the assistant for kids.');
    // A kid's every request counts, except one that answers tool calls the hub forwarded in a
    // turn it already counted for them: what a modified device can't make up.
    final carried = kid ? _carries(actor.id, answeredCalls(p, _decode(bytes))) : null;
    if (kid && carried == null && usage.dayUsedUp(actor.id)) {
      throw ApiError(429, 'daily_limit', 'That\'s all the assistant for today, ${actor.name}. Ask a parent if you need more.');
    }
    final free = p == ModelProvider.ollama;
    if (!free && usage.budgetSpent) {
      throw ApiError(402, 'budget_spent',
          'The assistant has used this month\'s budget. A parent can raise it in Settings, or it starts again next month.');
    }
    if (_forwarding >= maxForwarding) {
      throw ApiError(429, 'busy', 'The hub is busy with other questions. Try again in a moment.', details: {'retry': true});
    }
    _forwarding++;
    var answered = false;
    try {
      String? turn = carried?.turn;
      if (kid && turn == null) {
        await usage.countFor(actor.id);
        turn = '${actor.id}:${_turnIds++}';
      }
      final reply = await proxy.forward(model: model!, body: bytes);
      answered = reply.status == 200;
      final cost = reply.costUsd;
      if (cost != null && cost > 0) await usage.spend((cost * 1000000).round());
      if (kid && answered) _remember(actor.id, turn!, toolCalls(p, _decode(reply.body)));
      final month = _monthJson();
      return Response(reply.status, body: reply.body, headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
        'x-den-budget-spent-cents': '${month['spent_cents']}',
        'x-den-budget-cents': '${month['budget_cents']}',
      });
    } on ModelException catch (e) {
      throw ApiError(502, 'provider_unreachable', e.message, details: {'retry': e.retry});
    } finally {
      _forwarding--;
      // A carried-on request the provider didn't answer may be sent again, still carried on.
      if (carried != null && !answered) carried.giveBack();
    }
  }

  /// How long after the hub forwarded a tool call its answer still carries on that turn.
  static const Duration turnWindow = Duration(minutes: 10);

  /// Requests that may carry on one counted turn: den_assistant's loop makes at most eight
  /// tool calls a turn, each answered in a request of its own at most.
  static const int maxCarried = 8;

  /// Tool calls in answers the hub forwarded to kids, by call id: whose, in which counted turn,
  /// until when.
  final Map<String, ({String member, String turn, int until})> _calls = {};
  final Map<String, int> _carriedIn = {};
  int _turnIds = 0;

  /// The counted turn of [member]'s that a request answering [calls] carries on, or null when
  /// it starts a new one: every call must be one the hub forwarded to [member] in that turn,
  /// within [turnWindow], not answered before, and the turn mustn't have carried on
  /// [maxCarried] times. The calls are used up now; `giveBack` returns them.
  ({String turn, void Function() giveBack})? _carries(String member, List<String>? calls) {
    if (calls == null || calls.isEmpty) return null;
    final now = hub.now();
    _calls.removeWhere((_, c) => c.until <= now);
    final found = [for (final id in calls) _calls[id]];
    final first = found.first;
    if (first == null || found.any((c) => c == null || c.member != member || c.turn != first.turn)) return null;
    final turn = first.turn;
    final n = _carriedIn[turn] ?? 0;
    if (n >= maxCarried) return null;
    _carriedIn[turn] = n + 1;
    final taken = {for (final id in calls) id: _calls.remove(id)!};
    return (
      turn: turn,
      giveBack: () {
        _calls.addAll(taken);
        _carriedIn[turn] = (_carriedIn[turn] ?? 1) - 1;
      },
    );
  }

  /// Keeps the tool calls the provider asked for in [member]'s [turn], so their answers carry it
  /// on. Bounded: the oldest go first.
  void _remember(String member, String turn, List<String> calls) {
    final until = hub.now() + turnWindow.inMilliseconds;
    for (final id in calls) {
      _calls[id] = (member: member, turn: turn, until: until);
    }
    while (_calls.length > 10000) {
      _calls.remove(_calls.keys.first);
    }
    if (_carriedIn.length > 10000) _carriedIn.remove(_carriedIn.keys.first);
  }

  /// Reads [request]'s body once its headers pass [DeviceAuth.precheck]. A device that signed the
  /// body's hash in the headers is known to be in the family already; for one that didn't, the
  /// signature can only be checked once the body is in, so those are read one per client and
  /// two at a time (as for captures).
  Future<List<int>> _body(Request request) async {
    final claimed = await auth.precheck(request);
    const deadline = Duration(minutes: 2);
    if (claimed != null) return readBodyBytes(request, limit: maxBody, deadline: deadline);
    final key = hub.clientOf(request);
    final total = _unverified.values.fold(0, (a, b) => a + b);
    if ((_unverified[key] ?? 0) >= 1 || total >= 2) {
      throw ApiError(429, 'busy', 'The hub is busy. Try again in a moment.', details: {'retry': true});
    }
    _unverified[key] = (_unverified[key] ?? 0) + 1;
    try {
      return await readBodyBytes(request, limit: maxBody, deadline: deadline);
    } finally {
      final left = (_unverified[key] ?? 1) - 1;
      if (left <= 0) {
        _unverified.remove(key);
      } else {
        _unverified[key] = left;
      }
    }
  }

  final Map<String, int> _unverified = {};

  static Map<String, Object?> _decode(List<int> bytes) {
    try {
      final v = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return v is Map ? v.cast<String, Object?>() : const {};
    } on FormatException {
      return const {};
    }
  }

  /// The tool calls [json], a request for [provider], answers: null when it doesn't answer any
  /// (the person said something), else the ids of the calls its last message answers, empty
  /// when the provider's format carries none (a model at home, Gemini without ids), which the
  /// hub can't match to calls it forwarded.
  static List<String>? answeredCalls(ModelProvider provider, Map<String, Object?> json) {
    List<Object?> list(Object? v) => v is List ? v : const [];
    Map<Object?, Object?> map(Object? v) => v is Map ? v : const {};
    List<String> ids(Iterable<Object?> raw) {
      final out = <String>[];
      for (final id in raw) {
        if (id is! String || id.isEmpty) return const [];
        out.add(id);
      }
      return out;
    }

    switch (provider) {
      case ModelProvider.anthropic:
        final content = list(map(list(json['messages']).lastOrNull)['content']);
        final results = [for (final b in content) if (map(b)['type'] == 'tool_result') map(b)];
        return results.isEmpty ? null : ids(results.map((b) => b['tool_use_id']));
      case ModelProvider.openai || ModelProvider.xai:
        final results = <Map<Object?, Object?>>[];
        for (final item in list(json['input']).reversed) {
          if (map(item)['type'] != 'function_call_output') break;
          results.add(map(item));
        }
        return results.isEmpty ? null : ids(results.map((r) => r['call_id']));
      case ModelProvider.gemini:
        final parts = list(map(list(json['contents']).lastOrNull)['parts']);
        final results = [for (final p in parts) if (map(p).containsKey('functionResponse')) map(map(p)['functionResponse'])];
        return results.isEmpty ? null : ids(results.map((r) => r['id']));
      case ModelProvider.ollama:
        return map(list(json['messages']).lastOrNull)['role'] == 'tool' ? const [] : null;
    }
  }

  /// The ids of the tool calls in [json], [provider]'s answer to a request.
  static List<String> toolCalls(ModelProvider provider, Map<String, Object?> json) {
    List<Object?> list(Object? v) => v is List ? v : const [];
    Map<Object?, Object?> map(Object? v) => v is Map ? v : const {};
    final raw = switch (provider) {
      ModelProvider.anthropic => [
          for (final b in list(json['content']))
            if (map(b)['type'] == 'tool_use') map(b)['id'],
        ],
      ModelProvider.openai || ModelProvider.xai => [
          for (final o in list(json['output']))
            if (map(o)['type'] == 'function_call') map(o)['call_id'],
        ],
      ModelProvider.gemini => [
          for (final p in list(map(map(list(json['candidates']).firstOrNull)['content'])['parts']))
            if (map(p)['functionCall'] is Map) map(map(p)['functionCall'])['id'],
        ],
      ModelProvider.ollama => const <Object?>[],
    };
    return [for (final id in raw) if (id is String && id.isNotEmpty) id];
  }
}
