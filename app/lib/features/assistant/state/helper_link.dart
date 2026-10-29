import 'package:den_assistant/den_assistant.dart';
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../../../app/app_state.dart';
import '../../../platform/sync/den_network.dart';
import '../../../platform/sync/hub_api.dart';
import '../../../platform/sync/hub_client.dart' show HubException;
import '../words/assistant_words.dart' show notSetUpWords;

/// What the family's hub says about the AI helper for the person on this device
/// (`GET /api/v1/assistant`): who runs it, the models it offers, whether this person may use it,
/// a kid's questions today, and the month's budget. Never the key.
class HelperStatus {
  const HelperStatus({
    this.provider,
    this.speaker,
    this.models = const [],
    this.allowed = false,
    this.usedToday,
    this.dailyLimit,
    this.month = '',
    this.stopped = false,
  });

  factory HelperStatus.fromJson(Map<String, Object?> json) {
    Map<String, Object?> map(Object? v) => v is Map ? v.cast<String, Object?>() : const {};
    final provider = ModelProvider.byId(json['provider'] as String?);
    final models = [
      for (final m in json['models'] is List ? json['models']! as List : const [])
        if (map(m)['model'] is String) (map(m)['model']! as String, map(m)['size'] == 'large'),
    ]..sort((a, b) => (a.$2 ? 1 : 0) - (b.$2 ? 1 : 0));
    final you = map(json['you']);
    final month = map(json['this_month']);
    return HelperStatus(
      provider: provider,
      speaker: json['speaker'] as String? ?? provider?.speaker,
      models: [for (final m in models) m.$1],
      allowed: you['allowed'] == true,
      usedToday: (you['used_today'] as num?)?.toInt(),
      dailyLimit: (you['daily_limit'] as num?)?.toInt(),
      month: month['month'] as String? ?? '',
      stopped: month['stopped'] == true,
    );
  }

  /// Who runs it; null when a parent hasn't chosen.
  final ModelProvider? provider;

  /// What people call it: "Claude".
  final String? speaker;

  /// The model ids the hub offers, the small one first.
  final List<String> models;

  /// Whether the family's rules let this person use it.
  final bool allowed;

  /// A kid's questions so far today, and how many they get.
  final int? usedToday;
  final int? dailyLimit;

  /// `YYYY-MM`, and whether its budget is spent.
  final String month;
  final bool stopped;

  /// The model to use: the hub's small one.
  String? get model => models.firstOrNull;
}

/// How the helper reaches a model: the hub's status for this person, and a model that sends its
/// requests through the hub. Tests give a fake.
abstract interface class HelperLink {
  Future<HelperStatus> status();

  /// A model for [status]'s provider and model.
  Future<ChatModel> model(HelperStatus status);
}

/// The family hub as the helper's link. Every model request goes to the hub's
/// `/api/v1/assistant/model`, written in the provider's own format and signed with this device's
/// key for whoever is acting on it, the way capture's requests are; the hub adds its key and
/// enforces the family's rules. On the web the page may only talk to the hub (its
/// Content-Security-Policy), and native apps go the same way, so no device ever holds a key.
class HubHelperLink implements HelperLink {
  HubHelperLink(this.network, {http.Client? client})
    : _client = client ?? http.Client(),
      _api = HubApi(network, client: client);

  final DenNetwork network;
  final http.Client _client;
  final HubApi _api;

  @override
  Future<HelperStatus> status() async => HelperStatus.fromJson(
    await _api.send(
      'GET',
      '/api/v1/assistant',
      missing: "The family's hub doesn't run the AI helper yet. Update the hub, then try again.",
    ),
  );

  @override
  Future<ChatModel> model(HelperStatus status) async {
    final provider = status.provider;
    if (provider == null) throw const HubException(notSetUpWords);
    final bases = await network.hubBases();
    if (bases.isEmpty) throw const HubException("Den doesn't know the hub's address yet.");
    final models = [
      for (final base in bases)
        chatModelFor(
          provider,
          endpoint: ModelEndpoint.hub(base.replace(path: '/api/v1/assistant/model'), sign: _sign),
          model: status.model,
          client: _client,
        ),
    ];
    return models.length == 1 ? models.single : FailoverModel(models);
  }

  Future<Map<String, String>> _sign(String method, Uri url, List<int> body) async {
    final den = network.den;
    final hub = network.isHub ? den.deviceId : network.hubDevice?.id;
    if (hub == null) throw const HubException('This family has no hub yet.');
    return DeviceRequest.sign(keys: den.keys, method: method, url: url, body: body, hub: hub, actorId: den.actor?.id);
  }
}

/// The same model at each of the hub's addresses, tried in order while one can't be reached.
class FailoverModel extends ChatModel {
  FailoverModel(this.models) : assert(models.isNotEmpty);

  final List<ChatModel> models;
  int _working = 0;

  @override
  ModelInfo get info => models.first.info;

  @override
  Future<ModelReply> respond(ModelRequest request) async {
    for (var tried = 0; ; tried++) {
      try {
        return await models[_working].respond(request);
      } on ModelException catch (e) {
        if (e.kind != ModelFailure.network || tried >= models.length - 1) rethrow;
        _working = (_working + 1) % models.length;
      }
    }
  }
}

/// How the app reaches the helper. Tests set [links] (or put an [AssistantScope] above the app).
abstract final class Assistant {
  /// The link for [app]'s family: its hub, or null when the family has none.
  static HelperLink? Function(AppState app) links = hubLink;

  static final Expando<HubHelperLink> _hubLinks = Expando();

  /// The family hub's link, made once per network.
  static HelperLink? hubLink(AppState app) {
    final network = app.network;
    if (network == null || !(network.isHub || network.hubDevice != null)) return null;
    return _hubLinks[network] ??= HubHelperLink(network);
  }

  static HelperLink? linkFor(BuildContext context, AppState app) =>
      context.getInheritedWidgetOfExactType<AssistantScope>()?.link ?? links(app);
}

class AssistantScope extends InheritedWidget {
  const AssistantScope({super.key, required this.link, required super.child});

  final HelperLink? link;

  @override
  bool updateShouldNotify(AssistantScope oldWidget) => oldWidget.link != link;
}

/// Whether the AI helper is on for whoever is using this device: a parent turned it on for the
/// family and for them (parents always, once it's on; never a little kid or a pre-reader), the
/// family has a hub to run it through ([linked]), and this isn't a wall display or a shared
/// screen. Off by default.
bool helperOn(AppState app, {required bool linked}) {
  final me = app.den.actor;
  if (me == null || !linked) return false;
  if (app.wall || app.den.thisDevice?.mode == DeviceMode.shared) return false;
  return app.den.family?.assistant.allows(me) ?? false;
}
