import 'dart:convert';
import 'dart:typed_data';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:shelf/shelf.dart';

import 'context.dart';
import 'http_util.dart';

/// Requests a device of the family signs with its own key (den_net's [DeviceRequest]): the
/// capture reader, the parent's list of apps waiting to connect, opening "Add a device".
///
/// The signature covers the hex SHA-256 of the body. A device that also sends that hash in
/// [bodyHash] has its signature checked from the headers alone, before the hub reads a byte of
/// the body; one that doesn't (an older app) gets only the checks that need no body (signed
/// headers present, its clock, an approved device) before the body, so callers admit those few
/// at a time. Every refusal counts against the client's failed tries.
class DeviceAuth {
  /// Creates the checker for [hub].
  DeviceAuth(this.hub);

  /// Shared hub context.
  final HubContext hub;

  /// Header with the hex SHA-256 of the body the signature covers.
  static const String bodyHash = 'x-den-body-sha256';

  static final RegExp _hex = RegExp(r'^[0-9a-f]{64}$');

  final NonceBook _nonces = NonceBook();
  final NonceBook _early = NonceBook();

  /// Checks [request]'s headers before its body is read: signed, fresh, from an approved device
  /// of this family and, when it sends [bodyHash], signed by that device. Returns the claimed
  /// hash, or null when the device didn't send one. Throws `401` (or `429` past too many
  /// failures, `503` before the hub is ready).
  Future<String?> precheck(Request request) async {
    if (!hub.ready) throw ApiError.notReady();
    hub.checkFailures(request);
    String? h(String name) => request.headers[name];
    final id = h(DeviceRequest.device), sent = h(DeviceRequest.time);
    final nonce = h(DeviceRequest.nonce), sig = h(DeviceRequest.signature);
    if (id == null || sent == null || nonce == null || sig == null) throw _refuse(request, 'unsigned');
    final at = int.tryParse(sent);
    if (at == null || (hub.now() - at).abs() > DeviceRequest.skew.inMilliseconds) throw _refuse(request, 'clock');
    final device = hub.den.device(id);
    if (device == null || !device.approved || device.revoked) throw _refuse(request, 'unknown-device');
    if (hub.den.accessEnded(id)) throw _refuse(request, 'access-ended');
    final claimed = h(bodyHash)?.trim().toLowerCase();
    if (claimed == null) return null;
    if (!_hex.hasMatch(claimed)) throw _refuse(request, 'bad-hash');
    final bytes = signedBytes(
      method: request.method,
      url: request.requestedUri,
      time: at,
      nonce: nonce,
      bodyHash: claimed,
      device: id,
      actor: h(DeviceRequest.actor),
      hub: hub.den.deviceId,
    );
    if (!await verifySignature(bytes, sig, device.pubkey)) throw _refuse(request, 'bad-signature');
    if (!_early.add(id, nonce, hub.now())) throw _refuse(request, 'replay');
    return claimed;
  }

  /// The full check of [request] with its [body]: den_net's [DeviceRequest.verify], which also
  /// tells who is acting. A body that isn't the one the signature covers fails here. Throws
  /// `401`.
  Future<DeviceRequestCheck> verify(Request request, List<int> body) async {
    final c = await DeviceRequest.verify(
      hub.den,
      method: request.method,
      url: request.requestedUri,
      headers: request.headers,
      body: body,
      seen: _nonces,
    );
    if (!c.ok) throw _refuse(request, c.problem!);
    return c;
  }

  /// [precheck] and [verify] for a request with no body.
  Future<DeviceRequestCheck> check(Request request) async {
    await precheck(request);
    return verify(request, const []);
  }

  /// [precheck], a small body of at most [limit] bytes, and [verify]: who signed, and the body.
  Future<({DeviceRequestCheck check, List<int> body})> withBody(Request request, {int limit = 16 * 1024}) async {
    await precheck(request);
    final body = await readBodyBytes(request, limit: limit);
    return (check: await verify(request, body), body: body);
  }

  /// [c], when it is a parent acting on their own device (not a shared display); throws `403`
  /// with [message] for anyone else.
  static DeviceRequestCheck parentOf(DeviceRequestCheck c, {String message = 'Only a parent\'s own phone can do that.'}) {
    if (!(c.actor?.isParent ?? false) || c.device!.mode == DeviceMode.shared) throw ApiError.denied(message);
    return c;
  }

  /// [check], for a parent acting on their own device. Throws `403` for anyone else.
  Future<DeviceRequestCheck> parent(Request request, {String message = 'Only a parent\'s own phone can do that.'}) async =>
      parentOf(await check(request), message: message);

  ApiError _refuse(Request request, String problem) {
    hub.failed(request);
    hub.log.warn('Refused a signed request: $problem');
    return ApiError.unauthorized('This needs a request signed by a device in this family.');
  }
}

/// What a device signs for a request (den_net's `DeviceRequest`): `"den/device-request/v1"
/// 0x00` and the canonical JSON `[method, path with query, time, nonce, body hash, device,
/// actor, hub]`.
Uint8List signedBytes({
  required String method,
  required Uri url,
  required int time,
  required String nonce,
  required String bodyHash,
  required String device,
  required String? actor,
  required String hub,
}) {
  final path = url.hasQuery ? '${url.path}?${url.query}' : url.path;
  return Uint8List.fromList([
    ...utf8.encode('den/device-request/v1'),
    0,
    ...utf8.encode(canonicalJson([method.toUpperCase(), path, time, nonce, bodyHash, device, actor, hub])),
  ]);
}
