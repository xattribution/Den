/// The server's own settings, from a parent's phone (docs/hub-api.md, "The server"): how it
/// reaches the internet, its backups, and updating Den on it. Only a parent of the server's own
/// family, on their own personal phone, with a request it signs ([requireServerParent]); nothing
/// secret is ever in an answer: not the tunnel token, not the NAS's password.
///
/// - `GET /api/v1/hub/server`: the version, the Cloudflare tunnel's state and the family's
///   address, and what the updater says (`update`, absent without one).
/// - `PUT /api/v1/hub/server/internet {token}`: a new tunnel token.
/// - `POST /api/v1/hub/server/update`: "Update now".
/// - `GET /api/v1/hub/backups`: how the backups stand, and where they go.
/// - `POST /api/v1/hub/backups/run`: "Back up now".
/// - `POST /api/v1/hub/backups/find`: the NASes on the home network.
/// - `POST /api/v1/hub/backups/shares {place}`: the shared folders on one.
/// - `PUT /api/v1/hub/backups/place {place}`: back up there too, once a test copy worked.
/// - `DELETE /api/v1/hub/backups/place`: back up to the server's own disk only.
library;

import 'dart:convert';

import 'package:den_net/den_net.dart' show DeviceRequestCheck;
import 'package:shelf/shelf.dart';

import '../backup/rclone.dart';
import '../backup/sealed_backup.dart' show backupRecipientsOf;
import '../body.dart';
import '../config.dart' show hubVersion;
import '../context.dart';
import '../device_auth.dart';
import '../edge.dart';
import '../host.dart' show DenHost;
import '../http_util.dart';
import 'connector.dart';
import 'first_boot.dart' show FirstBoot;
import 'server_access.dart';

/// The server's settings endpoints, on each family's hub (only the server's own family's answer).
class ServerApi {
  /// For [hub] in [host], checking signed requests with [auth].
  ServerApi(this.hub, this.auth, this.host);

  /// Shared hub context.
  final HubContext hub;

  /// Checks the signed requests.
  final DeviceAuth auth;

  /// The host.
  final DenHost host;

  static const String _message = 'Only a parent\'s own phone can change the server\'s settings.';
  static const String _elsewhere = 'This is set up by whoever runs this server, in their own family.';

  /// Adds the routes.
  void register(Routes routes) {
    routes
      ..add('GET', '/api/v1/hub/server', (r, _) => _server(r))
      ..add('PUT', '/api/v1/hub/server/internet', (r, _) => _token(r))
      ..add('POST', '/api/v1/hub/server/update', (r, _) => _update(r))
      ..add('GET', '/api/v1/hub/backups', (r, _) => _backups(r))
      ..add('POST', '/api/v1/hub/backups/run', (r, _) => _run(r))
      ..add('POST', '/api/v1/hub/backups/find', (r, _) => _find(r))
      ..add('POST', '/api/v1/hub/backups/shares', (r, _) => _shares(r))
      ..add('PUT', '/api/v1/hub/backups/place', (r, _) => _setPlace(r))
      ..add('DELETE', '/api/v1/hub/backups/place', (r, _) => _clearPlace(r));
  }

  DeviceRequestCheck _allowed(DeviceRequestCheck c) => requireServerParent(hub, c, message: _message, elsewhere: _elsewhere);

  Future<({DeviceRequestCheck check, Map<String, Object?> json})> _signedJson(Request r) async {
    final signed = await auth.withBody(r, limit: 16 * 1024);
    final c = _allowed(signed.check);
    final json = signed.body.isEmpty ? <String, Object?>{} : _object(signed.body);
    return (check: c, json: json);
  }

  static Map<String, Object?> _object(List<int> body) {
    try {
      final v = jsonDecode(utf8.decode(body));
      if (v is Map) return v.cast<String, Object?>();
    } on FormatException {
      // Answered below.
    }
    throw ApiError.invalid('The body must be a JSON object.');
  }

  Future<Map<String, Object?>> _describeServer() async {
    final connector = host.connector;
    final tunnel = connector == null ? null : await connector.state();
    final update = await host.updater?.info();
    return {
      'version': update?.current ?? hubVersion,
      'internet': {
        'available': connector?.available ?? false,
        'token': tunnel?.token ?? false,
        'connected': tunnel?.connected ?? false,
        'reachable': tunnel?.reachable ?? false,
        'problem': ?tunnel?.message,
      },
      if (hub.config.publicUrl != null) 'address': hub.config.publicUrl.toString(),
      'update': ?update?.toJson(),
    };
  }

  Future<Response> _server(Request r) async {
    _allowed(await auth.check(r));
    return jsonResponse(await _describeServer());
  }

  Future<Response> _token(Request r) async {
    requireSecretsSafe(hub, r);
    final (:check, :json) = await _signedJson(r);
    hub.limit(r, 'server-setup', Limits.signInSetup, message: 'Too many tries. Wait a few minutes, then try again.');
    final connector = host.connector;
    if (connector == null || !connector.available) {
      throw ApiError(409, 'no_connector', 'This server can\'t connect to Cloudflare by itself. Update Den on the server.');
    }
    final token = tunnelTokenOf(Body(json).string('token', required: true, min: 1, max: 8000)!);
    if (token == null) {
      throw ApiError.invalid('That isn\'t a tunnel token. Copy the long one Cloudflare shows for the tunnel (it starts with eyJ).',
          field: 'token');
    }
    await connector.setToken(token);
    hub.log.info('${check.actor!.name} changed the Cloudflare tunnel token (tunnel ${tunnelIdOf(token) ?? 'unnamed'})');
    return jsonResponse(await _describeServer(), status: 202);
  }

  Future<Response> _update(Request r) async {
    final (:check, json: _) = await _signedJson(r);
    final updater = host.updater;
    final info = await updater?.info();
    if (updater == null || info == null) throw ApiError(409, 'no_updater', 'This server updates Den another way.');
    if (!info.newer) throw ApiError(409, 'up_to_date', 'Den is up to date on this server.');
    await updater.updateNow(by: check.actor!.name);
    hub.log.info('${check.actor!.name} asked to update Den to ${info.available}');
    return jsonResponse(await _describeServer(), status: 202);
  }

  Map<String, Object?> _describeBackups() {
    final b = host.backups;
    final s = b.status;
    final place = b.place;
    final names = [for (final r in backupRecipientsOf(hub.den)) r.name];
    return {
      'keep': b.keep,
      'running': b.running,
      'last': s.lastAt == null ? null : {'at': s.lastAt, 'size': ?s.lastSize},
      'problem': s.problem?.toJson(),
      'place': place == null ? null : {...place.describe(), 'last_at': ?s.placeLastAt},
      'opens_with': names,
      'disk': b.dir != null,
    };
  }

  Future<Response> _backups(Request r) async {
    _allowed(await auth.check(r));
    return jsonResponse(_describeBackups());
  }

  Future<Response> _run(Request r) async {
    await _signedJson(r);
    if (host.backups.dir == null) throw ApiError(409, 'no_disk', 'This server keeps no backups.');
    await host.backups.runNow();
    return jsonResponse(_describeBackups());
  }

  Future<Response> _find(Request r) async {
    await _signedJson(r);
    final found = await host.backups.finder.find();
    return jsonResponse({'found': [for (final f in found) f.toJson()]});
  }

  /// The place in [json], with the saved password when it names the same NAS and user and
  /// doesn't repeat it.
  BackupPlace _placeOf(Map<String, Object?> json) {
    final place = FirstBoot.placeIn(json);
    final saved = host.backups.place;
    if (place.password.isEmpty && saved != null && saved.host == place.host && saved.user == place.user && saved.kind == place.kind) {
      return place.withPassword(saved.password);
    }
    return place;
  }

  Future<Response> _shares(Request r) async {
    requireSecretsSafe(hub, r);
    final (check: _, :json) = await _signedJson(r);
    try {
      return jsonResponse({'shares': await host.backups.places.shares(_placeOf(json))});
    } on PlaceException catch (e) {
      throw FirstBoot.placeError(e);
    }
  }

  Future<Response> _setPlace(Request r) async {
    requireSecretsSafe(hub, r);
    final (:check, :json) = await _signedJson(r);
    final place = _placeOf(json);
    if (place.kind == 'nas' && place.share.isEmpty) throw ApiError.invalid('Pick a shared folder on the NAS.', field: 'share');
    try {
      await host.backups.places.test(place);
    } on PlaceException catch (e) {
      throw FirstBoot.placeError(e);
    }
    host.backups.setPlace(place);
    hub.log.info('${check.actor!.name} set backups to go to ${place.name ?? place.host} too');
    return jsonResponse(_describeBackups());
  }

  Future<Response> _clearPlace(Request r) async {
    final c = _allowed(await auth.check(r));
    if (host.backups.place != null) {
      host.backups.setPlace(null);
      hub.log.info('${c.actor!.name} set backups to stay on the server');
    }
    return jsonResponse(_describeBackups());
  }
}
