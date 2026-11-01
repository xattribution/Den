import 'dart:convert';

import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;

import 'den_network.dart';
import 'hub_client.dart';

/// Requests to the family hub's API signed with this device's key for whoever is acting on it
/// (den_net's [DeviceRequest]), tried at each address Den knows for the hub.
class HubApi {
  HubApi(this.network, {http.Client? client}) : _http = client ?? http.Client();

  final DenNetwork network;
  final http.Client _http;

  /// Sends [method] [path] with [body] as JSON and answers the JSON the hub sent back. Throws
  /// [HubException] with words for people; [missing] is the message when the hub doesn't know
  /// the endpoint (an older hub). With [secure] (a request carrying a secret) it goes only to the
  /// hub's `https` addresses this device was given ([DenNetwork.secureHubBases]): never over plain
  /// HTTP, never to a hub found on the home network.
  Future<Map<String, Object?>> send(String method, String path, {Map<String, Object?>? body, String? missing, bool secure = false}) async {
    final den = network.den;
    final hub = network.isHub ? den.deviceId : network.hubDevice?.id;
    if (hub == null) throw const HubException('This family has no hub yet.');
    final bases = secure ? await network.secureHubBases() : await network.hubBases();
    if (bases.isEmpty) {
      throw secure
          ? const HubException('Open Den at its https address to set this up.', code: 'needs_https')
          : const HubException("Den doesn't know the hub's address yet.");
    }
    final bytes = body == null ? const <int>[] : utf8.encode(jsonEncode(body));
    HubException? last;
    for (final base in bases) {
      final url = base.replace(path: path);
      final headers = await DeviceRequest.sign(
        keys: den.keys,
        method: method,
        url: url,
        body: bytes,
        hub: hub,
        actorId: den.actor?.id,
      );
      final request = http.Request(method, url)..headers.addAll(headers);
      if (body != null) {
        request.headers['content-type'] = 'application/json';
        request.bodyBytes = bytes;
      }
      final http.Response response;
      try {
        response = await http.Response.fromStream(await _http.send(request)).timeout(const Duration(seconds: 15));
      } on Object {
        last = HubException("Couldn't reach the hub at ${base.host}. Check the connection, then try again.");
        continue;
      }
      final json = decodeHubJson(response.body);
      if (response.statusCode >= 200 && response.statusCode < 300) return json;
      if (response.statusCode == 404 && missing != null && hubErrorCode(json) == 'not_found') {
        throw HubException(missing, code: 'not_found');
      }
      throw hubError(response, json);
    }
    throw last ?? const HubException("Couldn't reach the hub.");
  }

  void close() => _http.close();
}

/// [text] as a JSON object, or empty.
Map<String, Object?> decodeHubJson(String text) {
  try {
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  } on Object {
    return const {};
  }
}

/// The API error code in an error answer (`rate_limited`, `link_closed`, ...).
String? hubErrorCode(Map<String, Object?> json) => json['error'] is Map ? (json['error']! as Map)['code'] as String? : null;

/// An error answer from the hub as words for people: what happened and what to do (see "Errors"
/// in docs/hub-api.md). The hub's own message where it already says both.
HubException hubError(http.Response response, Map<String, Object?> json) {
  final error = json['error'] is Map ? Map<String, Object?>.from(json['error']! as Map) : json;
  final details = error['details'] is Map ? Map<String, Object?>.from(error['details']! as Map) : const <String, Object?>{};
  final code = error['code'] as String?;
  final status = response.statusCode;
  final retry = (details['retry_after'] as num?)?.toInt() ?? int.tryParse(response.headers['retry-after'] ?? '');
  final message = switch ((status, code)) {
    (429, 'rate_limited') => 'Too many tries from here. Try again in ${waitWords(retry ?? 60)}.',
    (429, 'busy') => 'The hub is busy right now. Try again in a moment.',
    (408, _) => 'The connection was too slow to send that. Try again on a better connection.',
    (413, _) => "That's too large to send to the hub. Try something smaller.",
    _ => error['message'] as String? ?? 'The hub refused that ($status).',
  };
  return HubException(message, code: code, triesLeft: (details['tries_left'] as num?)?.toInt(), retryAfter: retry);
}

/// "a minute", "5 minutes", "an hour" for a wait of [seconds].
String waitWords(int seconds) {
  if (seconds <= 60) return 'a minute';
  final minutes = (seconds / 60).ceil();
  if (minutes < 60) return '$minutes minutes';
  final hours = (minutes / 60).ceil();
  return hours == 1 ? 'an hour' : '$hours hours';
}
