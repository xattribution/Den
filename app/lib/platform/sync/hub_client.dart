import 'dart:async';
import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:http/http.dart' as http;

import 'hub_api.dart';

/// What `GET /api/v1/hub/status` says about a hub.
class HubInfo {
  const HubInfo({
    required this.base,
    required this.paired,
    required this.device,
    required this.name,
    required this.stage,
    this.lastError,
    this.matchingWords = const [],
    this.firstBoot,
  });

  /// What a fresh server's first-boot pages say comes first: `start` (connect it to the
  /// internet, then make or restore the family) or `family` (that was done: make the family
  /// here). Null on a hub without them, where the setup link starts the family at once.
  final String? firstBoot;

  /// The hub's HTTP base address, `http://192.168.1.20:47733`.
  final Uri base;
  final bool paired;

  /// The hub's device id.
  final String device;
  final String name;

  /// `waiting_for_code`, `joining`, `waiting_for_approval`, `syncing` or `ready`.
  final String stage;
  final String? lastError;

  /// The three words from the hub's pairing session with the phone that invited it, while it
  /// waits to be approved; empty otherwise.
  final List<String> matchingWords;

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

/// An invite the hub keeps for a parent (`POST /api/v1/invites`).
class HubInvite {
  const HubInvite({
    required this.words,
    required this.link,
    required this.expires,
    this.member,
    this.bySlot = false,
    this.preapproved = false,
  });

  /// The words the hub chose; empty when it keeps the invite by the slot of words this device
  /// chose ([bySlot]), which it never learns.
  final List<String> words;

  /// `https://<hub>/#/join/<word>-<word>-<word>-<word>`; for an invite kept by its slot, the
  /// hub's address the link goes on.
  final Uri link;

  /// UTC milliseconds.
  final int expires;
  final String? member;

  /// The hub keeps it under the slot this device sent (an older hub ignores the slot and picks
  /// words of its own).
  final bool bySlot;

  /// It carries an invite key, so whoever opens it is let in at once.
  final bool preapproved;
}

/// What an invite's words opened (`POST /api/v1/invites/redeem`): the invite to join with, who
/// it is for, and the family's name.
class RedeemedInvite {
  const RedeemedInvite({
    required this.invite,
    this.member,
    this.memberName,
    this.memberMarker,
    this.memberPicture,
    this.familyName,
    this.preapproved = false,
  });

  /// A `den://join` invite naming the hub.
  final String invite;
  final String? member;
  final String? memberName;

  /// Their color and picture, to show their face before this device holds the family.
  final String? memberMarker;
  final String? memberPicture;
  final String? familyName;

  /// The invite carries a key the family made: the words let this device in at once.
  final bool preapproved;
}

/// What a recovery code from whoever runs the hub opened (`POST /api/v1/recovery/redeem`):
/// the invite to join over, the hub's recovery proof for this device, and whose it is.
class RedeemedRecovery {
  const RedeemedRecovery({
    required this.invite,
    required this.proof,
    required this.member,
    required this.memberName,
    this.familyName,
  });

  /// A `den://join` invite naming the hub.
  final String invite;

  /// The hub's signed recovery proof (den_core's `RecoveryProof` as JSON).
  final Map<String, Object?> proof;
  final String member;
  final String memberName;
  final String? familyName;
}

/// A hub turned a request down; [message] says why and what to do, for people.
class HubException implements Exception {
  const HubException(this.message, {this.code, this.triesLeft, this.retryAfter});
  final String message;

  /// The API's error code (`permission_denied`, `already_set_up`, `busy`, ...).
  final String? code;

  /// Setup codes left before the hub makes this device wait.
  final int? triesLeft;

  /// Seconds to wait before trying again, after `429`.
  final int? retryAfter;

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
      firstBoot: json['first_boot'] is Map ? (json['first_boot']! as Map)['next'] as String? : null,
      matchingWords: [
        if (json['matching_words'] case final List<Object?> words)
          for (final w in words)
            if (w is String) w,
      ],
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

  /// `POST /api/v1/invites` with a parent's signed invite grant, and the slot of the words this
  /// device chose and the invite key's public half when it has them.
  Future<HubInvite> createInvite(Uri base, Map<String, Object?> grant) async {
    final json = await _send(
      () => _http.post(
        base.replace(path: '/api/v1/invites'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(grant),
      ),
      base,
    );
    return HubInvite(
      words: [
        if (json['words'] case final List<Object?> words)
          for (final w in words)
            if (w is String) w,
      ],
      link: Uri.parse(json['link'] as String? ?? json['base'] as String? ?? base.toString()),
      expires: (json['expires_ms'] as num?)?.toInt() ?? 0,
      member: json['member'] as String?,
      bySlot: json['slot'] is String,
      preapproved: json['preapproved'] == true,
    );
  }

  /// `POST /api/v1/invites/redeem` with the slot an invite's words stretch to, or the four words
  /// themselves ([code]) for an invite whose words the hub chose.
  Future<RedeemedInvite> redeemInvite(Uri base, {String? code, String? slot}) async {
    final json = await _send(
      () => _http.post(
        base.replace(path: '/api/v1/invites/redeem'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'slot': ?slot, if (slot == null) 'code': code}),
      ),
      base,
    );
    final invite = json['invite'];
    if (invite is! String) throw const HubException("The hub's answer had no invite in it. Try again.");
    return RedeemedInvite(
      invite: invite,
      member: json['member'] as String?,
      memberName: json['member_name'] as String?,
      memberMarker: json['member_marker'] as String?,
      memberPicture: json['member_picture'] as String?,
      familyName: json['family'] as String?,
      preapproved: json['preapproved'] == true,
    );
  }

  /// `POST /api/v1/recovery/redeem` with the four words from whoever runs the hub and this
  /// device's key.
  Future<RedeemedRecovery> redeemRecovery(Uri base, String code, String pubkey) async {
    final json = await _send(
      () => _http.post(
        base.replace(path: '/api/v1/recovery/redeem'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'code': code, 'pubkey': pubkey}),
      ),
      base,
    );
    final invite = json['invite'], proof = json['proof'], member = json['member'], name = json['member_name'];
    if (invite is! String || proof is! Map || member is! String || name is! String) {
      throw const HubException("The hub's answer was missing something. Try again.");
    }
    return RedeemedRecovery(
      invite: invite,
      proof: proof.cast<String, Object?>(),
      member: member,
      memberName: name,
      familyName: json['family'] as String?,
    );
  }

  /// `POST /api/v1/screens/{path}` from a kitchen screen with no family: `code` (show a code),
  /// `code/status` and `code/join`. Answers the hub's JSON.
  Future<Map<String, Object?>> screen(Uri base, String path, Map<String, Object?> body) => _send(
        () => _http.post(
          base.replace(path: '/api/v1/screens/$path'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(body),
        ),
        base,
      );

  void close() => _http.close();

  Future<Map<String, Object?>> _send(Future<http.Response> Function() request, Uri base) async {
    final http.Response response;
    try {
      response = await request().timeout(_timeout);
    } on Object {
      throw HubException(
        "Couldn't reach a hub at ${base.host}${base.hasPort ? ':${base.port}' : ''}. "
        'Check the address and the connection, then try again.',
      );
    }
    final body = decodeHubJson(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) return body;
    throw hubError(response, body);
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
