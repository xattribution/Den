import 'dart:math';
import 'dart:typed_data';

import 'package:den_core/den_core.dart';

import 'util.dart';

/// An HTTP request a device makes to its family's hub, signed with the device's own key so
/// the hub knows which approved device asked and for whom, without a token. Used where a
/// device asks the hub for a service (reading a capture) rather than syncing.
///
/// Headers: `X-Den-Device` (device id), `X-Den-Time` (UTC ms), `X-Den-Nonce`, optional
/// `X-Den-Actor` (the member acting on that device), `X-Den-Signature`: base64url Ed25519
/// over `"den/device-request/v1" 0x00 | canonical JSON [method, path, time, nonce,
/// sha256(body) hex, device, actor, hub]`, and `X-Den-Hub`, the hub device it is addressed to
/// (the same id the signature covers), so a server holding several families' logs (a Den host)
/// hands it to that family's hub without guessing. The hub ([DeviceRequest.verify]) accepts it
/// only from an approved, unrevoked device of its family, addressed to itself, within five
/// minutes of its own clock, with a nonce it hasn't seen. A request without `X-Den-Hub` (an
/// older app) goes to the family whose address it came to.
abstract final class DeviceRequest {
  /// The signing device's id.
  static const device = 'x-den-device';

  /// When it was signed, UTC milliseconds.
  static const time = 'x-den-time';

  /// Random, so no request is accepted twice.
  static const nonce = 'x-den-nonce';

  /// The member acting on the device, when it names one.
  static const actor = 'x-den-actor';

  /// The device's signature.
  static const signature = 'x-den-signature';

  /// The hub device the request is addressed to. Only routing: the signature already covers
  /// the same id, so a header naming another hub makes the signature fail there.
  static const hubHeader = 'x-den-hub';

  /// How far a request's time may be from the hub's.
  static const Duration skew = Duration(minutes: 5);

  static final Random _random = Random.secure();

  /// The headers that sign a [method] request to [url] with [body], addressed to the hub
  /// device [hub], acting as [actorId].
  static Future<Map<String, String>> sign({
    required DeviceKeys keys,
    required String method,
    required Uri url,
    required List<int> body,
    required String hub,
    String? actorId,
    int? now,
  }) async {
    final deviceId = await keys.deviceId();
    final at = now ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    final n = b64e(List.generate(16, (_) => _random.nextInt(256)));
    final sig = await keys.sign(
      await _bytes(method.toUpperCase(), _path(url), at, n, body, deviceId, actorId, hub),
    );
    return {
      device: deviceId,
      time: '$at',
      nonce: n,
      actor: ?actorId,
      signature: sig,
      hubHeader: hub,
    };
  }

  /// Who made a request with [headers], or why the hub ([den]) must refuse it. [seen] holds
  /// the nonces of recent requests, so none is accepted twice.
  static Future<DeviceRequestCheck> verify(
    Den den, {
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required List<int> body,
    required NonceBook seen,
    int? now,
  }) async {
    String? header(String name) => headers[name] ?? headers[name.toLowerCase()];
    final id = header(device), sent = header(time), n = header(nonce), sig = header(signature);
    final actorId = header(actor);
    if (id == null || sent == null || n == null || sig == null) return const DeviceRequestCheck.refused('unsigned');
    final at = int.tryParse(sent);
    final clock = now ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    if (at == null || (clock - at).abs() > skew.inMilliseconds) return const DeviceRequestCheck.refused('clock');
    if (!den.hasFamily) return const DeviceRequestCheck.refused('no-family');
    final d = den.device(id);
    if (d == null || !d.approved || d.revoked) return const DeviceRequestCheck.refused('unknown-device');
    final bytes = await _bytes(method.toUpperCase(), _path(url), at, n, body, id, actorId, den.deviceId);
    if (!await verifySignature(bytes, sig, d.pubkey)) return const DeviceRequestCheck.refused('bad-signature');
    if (!seen.add(id, n, clock)) return const DeviceRequestCheck.refused('replay');

    // Who is acting: a personal device only for its owner; a shared display for whoever
    // signed in on it (the family already trusts it to say so for its own changes); a hub for
    // its owner, or the member it names.
    Member? acting;
    if (actorId != null) {
      acting = den.member(actorId);
      if (acting == null) return const DeviceRequestCheck.refused('unknown-member');
    }
    switch (d.mode) {
      case DeviceMode.personal:
        if (actorId != null && actorId != d.member) return const DeviceRequestCheck.refused('not-the-owner');
        acting = d.member == null ? null : den.member(d.member!);
      case DeviceMode.hub:
        acting ??= d.member == null ? null : den.member(d.member!);
      case DeviceMode.shared:
        break;
    }
    return DeviceRequestCheck.ok(d, acting);
  }

  static String _path(Uri url) => url.hasQuery ? '${url.path}?${url.query}' : url.path;

  static Future<Uint8List> _bytes(
    String method,
    String path,
    int at,
    String nonce,
    List<int> body,
    String device,
    String? actor,
    String hub,
  ) async =>
      concatBytes([
        utf8Bytes('den/device-request/v1'),
        [0],
        utf8Bytes(canonicalJson([method, path, at, nonce, hexEncode(await sha256(body)), device, actor, hub])),
      ]);
}

/// What [DeviceRequest.verify] found.
class DeviceRequestCheck {
  /// A good request from [device], acting as [actor].
  const DeviceRequestCheck.ok(Device this.device, this.actor) : problem = null;

  /// A refused request, and why.
  const DeviceRequestCheck.refused(String this.problem)
      : device = null,
        actor = null;

  /// The approved device that signed, when the request is good.
  final Device? device;

  /// The member acting on it, or null (a shared display nobody signed in to).
  final Member? actor;

  /// Why it was refused, for the log: `unsigned`, `clock`, `unknown-device`, `bad-signature`,
  /// `replay`, `unknown-member`, `not-the-owner`, `no-family`.
  final String? problem;

  /// Whether the request is good.
  bool get ok => problem == null;
}

/// Nonces of recent signed requests, per device, kept as long as their time could still pass
/// [DeviceRequest.verify]'s clock check.
class NonceBook {
  final Map<String, int> _seen = {};

  /// Records [nonce] from [device]; false when it was already used.
  bool add(String device, String nonce, int now) {
    final horizon = now - 2 * DeviceRequest.skew.inMilliseconds;
    if (_seen.length > 4096) _seen.removeWhere((_, at) => at < horizon);
    final key = '$device|$nonce';
    final last = _seen[key];
    if (last != null && last >= horizon) return false;
    _seen[key] = now;
    return true;
  }
}
