/// The web app keyboard_e2e.mjs opens for its Ask checks: the demo family, with the AI helper on
/// for parents and the family's hub played by the test's own server at the page's origin, the
/// way Caddy serves the real hub. The helper's calls go out exactly as in the app (the Claude
/// adapter, `GET /api/v1/assistant`, `POST /api/v1/assistant/model`, same origin, under the
/// hub's Content-Security-Policy); only the request signing is left out, since the demo family
/// has no hub to sign for. Not a test itself; build it from app/ with:
///
///   flutter build web --release --csp --dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/ \
///     -t test/web/ask_e2e_app.dart -o "$PWD/build/web_ask"
library;

import 'dart:convert';

import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/den_app.dart';
import 'package:den_app/features/assistant/assistant.dart';
import 'package:den_assistant/den_assistant.dart';
import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/data/latest_all.dart' as tzdata;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  final den = await createDemoFamily();
  await den.updateFamily({'assistant': const AssistantPolicy(enabled: true).toJson()});
  final link = PageOriginLink(http.Client());
  Assistant.links = (_) => link;
  runApp(DenApp(state: AppState(den)));
}

/// The family's hub at the page's own origin, reached through [client]: the hub's two helper
/// endpoints and the provider's own adapter, as `HubHelperLink` uses them, without signing.
class PageOriginLink implements HelperLink {
  PageOriginLink(this.client);

  final http.Client client;

  Uri _at(String path) => Uri.parse('${Uri.base.origin}$path');

  @override
  Future<HelperStatus> status() async {
    final response = await client.get(_at('/api/v1/assistant'));
    return HelperStatus.fromJson(Map<String, Object?>.from(jsonDecode(response.body) as Map));
  }

  @override
  Future<ChatModel> model(HelperStatus status) async => chatModelFor(
        status.provider!,
        endpoint: ModelEndpoint.hub(_at('/api/v1/assistant/model'), sign: (method, url, body) async => const {}),
        model: status.model,
        client: client,
      );
}
