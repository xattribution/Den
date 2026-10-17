import 'dart:async';
import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:http/http.dart' as http;

/// What `GET /api/v1/hub/status` says about a hub.
class HubInfo {
  const HubInfo({
    required this.base,
    required this.paired,
    required this.device,
    required this.name,
    required this.stage,
    this.lastError,
  });

  /// The hub's HTTP base address, `http://192.168.1.20:47733`.
  final Uri base;
  final bool paired;

  /// The hub's device id.
  final String device;
  final String name;

  /// `waiting_for_code`, `joining`, `waiting_for_approval`, `syncing` or `ready`.
  final String stage;
  final String? lastError;

  /// The address as people type it: `192.168.1.20:47733`.
  String get address => base.hasPort ? '${base.host}:${base.port}' : base.host;
}

/// A hub that answered on the home network.
class FoundHub {
  const FoundHub({required this.name, required this.base, this.deviceId, this.familyId});
  final String name;
  final Uri base;
  final String? deviceId;

  /// The family it belongs to, or null for a fresh hub waiting for its setup code.
  final String? familyId;

  String get address => base.hasPort ? '${base.host}:${base.port}' : base.host;
}

/// A browser's link code at its hub: the `den://link` URI to show and the secret it polls with.
class LinkSlot {
  const LinkSlot({required this.slot, required this.secret, required this.uri, required this.expires});
  final String slot;
  final String secret;
  final String uri;

  /// UTC milliseconds.
  final int expires;
}

/// A hub turned a request down; [message] says why and what to do, for people.
class HubException implements Exception {
  const HubException(this.message, {this.code, this.triesLeft});
  final String message;

  /// The API's error code (`permission_denied`, `already_set_up`, `busy`, ...).
  final String? code;

  /// Setup codes left before the hub prints a new one.
  final int? triesLeft;

  @override
  String toString() => message;
}

/// The hub's small unauthenticated HTTP surface the app uses: status, setup and browser links.
class HubClient {
  HubClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;
  static const _timeout = Duration(seconds: 10);

  /// Turns "192.168.1.20", "den-hub.local:47733", "ws://…/ws" or "https://den.example.com" into
  /// the hub's HTTP base address, or null when it isn't an address.
  static Uri? baseFor(String address) {
    var text = address.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'http://$text';
    final parsed = Uri.tryParse(text);
    if (parsed == null || parsed.host.isEmpty) return null;
    final secure = parsed.scheme == 'https' || parsed.scheme == 'wss';
    return Uri(
      scheme: secure ? 'https' : 'http',
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : (secure ? 443 : 47733),
    );
  }

  /// The hub's sync WebSocket for [base].
  static Uri syncUri(Uri base) => base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '/ws');

  /// `GET /api/v1/hub/status`.
  Future<HubInfo> status(Uri base) async {
    final json = await _send(() => _http.get(base.replace(path: '/api/v1/hub/status')), base);
    return HubInfo(
      base: base,
      paired: json['paired'] == true,
      device: json['device'] as String? ?? '',
      name: json['name'] as String? ?? 'Den hub',
      stage: json['stage'] as String? ?? 'waiting_for_code',
      lastError: json['last_error'] as String?,
    );
  }

  /// `POST /api/v1/hub/setup`: the setup code and an invite for the hub to join with. With
  /// [direct] the phone then opens `/api/v1/hub/setup/ws` and serves its side there.
  Future<void> sendSetup(Uri base, {required String code, required String invite, bool direct = true}) async {
    await _send(
      () => _http.post(
        base.replace(path: '/api/v1/hub/setup'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'code': code, 'invite': invite, 'direct': direct}),
      ),
      base,
    );
  }

  /// `POST /api/v1/link`, from a browser the hub served.
  Future<LinkSlot> openLink(Uri base) async {
    final json = await _send(() => _http.post(base.replace(path: '/api/v1/link')), base);
    return LinkSlot(
      slot: json['slot']! as String,
      secret: json['secret']! as String,
      uri: json['uri']! as String,
      expires: (json['expires_ms'] as num?)?.toInt() ?? DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch,
    );
  }

  /// `GET /api/v1/link/{slot}`: the invite a parent's phone left, or null while still waiting.
  Future<String?> pollLink(Uri base, LinkSlot slot) async {
    final json = await _send(
      () => _http.get(
        base.replace(path: '/api/v1/link/${slot.slot}'),
        headers: {'x-den-link-secret': slot.secret},
      ),
      base,
    );
    return json['state'] == 'ready' ? json['invite'] as String? : null;
  }

  /// `POST /api/v1/link/{slot}` with a signed invite grant, from a parent's phone.
  Future<void> grantLink(Uri base, String slot, Map<String, Object?> grant) async {
    await _send(
      () => _http.post(
        base.replace(path: '/api/v1/link/$slot'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(grant),
      ),
      base,
    );
  }

  void close() => _http.close();

  Future<Map<String, Object?>> _send(Future<http.Response> Function() request, Uri base) async {
    final http.Response response;
    try {
      response = await request().timeout(_timeout);
    } on Object {
      throw HubException(
        "Couldn't reach a hub at ${base.host}${base.hasPort ? ':${base.port}' : ''}. "
        'Check the address and that the hub is on the same network.',
      );
    }
    Map<String, Object?> body;
    try {
      body = Map<String, Object?>.from(jsonDecode(response.body) as Map);
    } on Object {
      body = const {};
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return body;
    final error = body['error'] is Map ? Map<String, Object?>.from(body['error']! as Map) : body;
    final details = error['details'] is Map ? Map<String, Object?>.from(error['details']! as Map) : const {};
    throw HubException(
      error['message'] as String? ?? 'The hub refused that (${response.statusCode}).',
      code: error['code'] as String?,
      triesLeft: (details['tries_left'] as num?)?.toInt(),
    );
  }
}

/// A `den://link?hub=&slot=&u=` code scanned from a browser.
class LinkCode {
  const LinkCode({required this.hubDevice, required this.slot, required this.base});
  final String hubDevice;
  final String slot;
  final Uri base;

  static LinkCode? parse(String text) {
    final t = text.trim();
    if (!t.startsWith('den://link?')) return null;
    final q = Uri.splitQueryString(t.substring('den://link?'.length));
    final hub = q['hub'], slot = q['slot'], u = q['u'];
    final base = u == null ? null : Uri.tryParse(u);
    if (hub == null || slot == null || base == null || base.host.isEmpty) return null;
    return LinkCode(hubDevice: hub, slot: slot, base: Uri(scheme: base.scheme, host: base.host, port: base.port));
  }
}

/// Whether [den] already has [deviceId] as an approved hub.
bool isFamilyHub(Den den, String deviceId) {
  final d = den.device(deviceId);
  return d != null && d.approved && !d.revoked && d.mode == DeviceMode.hub;
}
