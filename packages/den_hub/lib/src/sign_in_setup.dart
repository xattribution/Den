/// Signing in with Google and Apple, set up from a parent's phone (docs/hub-api.md, "Setting up
/// signing in with Google and Apple"): no file to edit, no restart.
///
/// The host keeps one set of providers for every family on it ([HostSignIn]), as Google and
/// Apple see one client with each family's address registered as a place to come back to. What a
/// parent pasted from Google's and Apple's consoles is kept in the data of the host's own family
/// (`<data>/hub/sign-in.json`: in its backups, its owner's alone from the moment it is written),
/// never in a family's log, never in an answer and never in the hub's log: the API says only
/// whether each provider is on, when and by whom.
///
/// Who may change it ([HubSignInSetup]): a parent of the host's own family (the family in the
/// host's data directory itself, the one `install.sh` set up: whoever runs the server), on their
/// own personal phone, by a request it signs. A shared screen, a hub-mode device, or a token
/// can't; a parent of another family on the host can't even see it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart' show DeviceMode;
import 'package:den_net/den_net.dart' show DeviceRequestCheck;
import 'package:shelf/shelf.dart';

import 'context.dart';
import 'device_auth.dart';
import 'edge.dart';
import 'host.dart' show DenHost;
import 'host_state.dart' show HostState;
import 'http_util.dart';
import 'log.dart';
import 'oidc.dart';
import 'setup.dart' show restrictToOwner;

/// The file in a family's `hub/` directory that holds the host's sign-in settings.
const String signInFile = 'sign-in.json';

/// Google's OAuth client, as a parent pasted it from Google's console.
class GoogleClient {
  /// The client [clientId] with [clientSecret].
  const GoogleClient({required this.clientId, required this.clientSecret});

  /// `1234567890-abc.apps.googleusercontent.com`.
  final String clientId;

  /// `GOCSPX-...`.
  final String clientSecret;
}

/// Sign in with Apple, as a parent pasted it from Apple's developer account.
class AppleClient {
  /// The Services ID [servicesId], with the key [keyId] of the team [teamId], whose `.p8` is [key].
  const AppleClient({required this.servicesId, required this.teamId, required this.keyId, required this.key});

  /// The Services ID, the client id (`family.den.signin`).
  final String servicesId;

  /// The Apple Developer team (10 letters and digits).
  final String teamId;

  /// The key's id (10 letters and digits).
  final String keyId;

  /// The `.p8` file's text (PEM).
  final String key;
}

/// What's wrong with [id] as a Google OAuth client id, in words for people; null when it looks
/// like one.
String? googleClientIdProblem(String id) {
  if (id.isEmpty) return 'Paste the client ID.';
  if (id.startsWith('GOCSPX-')) return 'That\'s the client secret. The client ID ends in .apps.googleusercontent.com.';
  if (!RegExp(r'^[0-9]{3,30}-[a-z0-9]{8,64}\.apps\.googleusercontent\.com$').hasMatch(id)) {
    return 'That isn\'t a Google client ID. It looks like 1234567890-abc123.apps.googleusercontent.com: copy it '
        'from the client\'s page in Google\'s console.';
  }
  return null;
}

/// What's wrong with [secret] as a Google client secret; null when it looks like one.
String? googleSecretProblem(String secret) {
  if (secret.isEmpty) return 'Paste the client secret too.';
  if (secret.endsWith('.apps.googleusercontent.com')) return 'That\'s the client ID. The secret is the other one, starting GOCSPX-.';
  if (secret.length < 8 || secret.length > 200 || RegExp(r'\s').hasMatch(secret)) return 'That doesn\'t look like a client secret.';
  return null;
}

/// What's wrong with [id] as an Apple Services ID; null when it looks like one.
String? appleServicesIdProblem(String id) {
  if (id.isEmpty) return 'Paste the Services ID.';
  if (!RegExp(r'^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$').hasMatch(id) || id.length > 155) {
    return 'That isn\'t a Services ID. It looks like family.den.signin.';
  }
  return null;
}

/// What's wrong with [id] as an Apple Team ID or Key ID ([what]); null when it looks like one.
String? appleTenProblem(String id, String what) {
  if (id.isEmpty) return 'Paste the $what.';
  if (!RegExp(r'^[A-Z0-9]{10}$').hasMatch(id)) return 'The $what is 10 letters and digits, like ABCDE12345.';
  return null;
}

/// The host's sign-in settings, and the providers they make. The host's own family hands it its
/// data directory as it starts ([attach]); until then, and after it stops, no family on the host
/// signs anyone in. A change takes effect at once for every family: the next sign-in uses it.
class HostSignIn {
  /// Settings whose providers live at their usual issuers, or at [issuers] (tests point them at
  /// fakes: `{'google': ..., 'apple': ...}`).
  HostSignIn({this.issuers = const {}});

  /// Where the providers are, when not at Google's and Apple's own.
  final Map<String, Uri> issuers;

  String? _hub;
  String? _dir;
  HubLog? _log;
  Map<String, Object?> _doc = const {};
  OidcProvider? _google;
  OidcProvider? _apple;

  /// The hub device of the host's own family, whose parents may change these; null until it is
  /// attached.
  String? get hostFamily => _hub;

  final Map<String, int> _generations = {googleProvider: 0, appleProvider: 0};

  /// How many times [provider] was turned on, changed or off (or the host's own family came or
  /// went) since the host started. Sign-ins, sessions and bindings remember the generation they
  /// began under and end when it moves on, so turning a provider off or changing its client
  /// ends everything that came through the old one, in every family.
  int generationOf(String provider) => _generations[provider] ?? 0;

  void _bump(String provider) => _generations[provider] = generationOf(provider) + 1;

  void _bumpAll() {
    _bump(googleProvider);
    _bump(appleProvider);
  }

  /// Throws [StateError] while the host's own family isn't attached: nothing is kept then, so a
  /// change that was on its way when the family stopped can't turn a provider back on or write
  /// over what is saved.
  void _requireAttached() {
    if (_hub == null) throw StateError('The host\'s own family isn\'t attached');
  }

  /// The providers on now, Google first; null when none is.
  SignInProviders? get providers => _google == null && _apple == null ? null : SignInProviders(google: _google, apple: _apple);

  /// Whether [provider] is on.
  bool isOn(String provider) => switch (provider) {
        googleProvider => _google != null,
        appleProvider => _apple != null,
        _ => false,
      };

  /// When [provider] was turned on (UTC ms) and by which member, or null when it is off.
  ({int at, String? by})? setOf(String provider) {
    if (!isOn(provider)) return null;
    final entry = _doc[provider];
    final at = entry is Map ? entry['set_at'] : null;
    final by = entry is Map ? entry['set_by'] : null;
    return (at: at is int ? at : 0, by: by is String ? by : null);
  }

  /// Takes the settings of the host's own family, the hub [hubDevice], whose data is in
  /// [dataDir] (null: in memory only): reads them, and turns on what they set up. A provider
  /// whose settings can't be read stays off, and [log] says so (never what they hold).
  void attach({required String hubDevice, String? dataDir, required HubLog log}) {
    _hub = hubDevice;
    _dir = dataDir;
    _log = log;
    _bumpAll();
    _ownerOnly();
    _doc = _read();
    _google = _googleFrom(_doc[googleProvider]);
    _apple = _appleFrom(_doc[appleProvider]);
    final on = [?_google?.name, ?_apple?.name];
    if (on.isNotEmpty) log.info('Signing in with ${on.join(' and ')}');
  }

  /// The host's own family stopped: no family signs anyone in until it is back.
  void detach(String hubDevice) {
    if (_hub != hubDevice) return;
    _hub = null;
    _dir = null;
    _google = null;
    _apple = null;
    _doc = const {};
    _bumpAll();
  }

  /// The provider [c] makes (it isn't on until [setGoogle]).
  OidcProvider googleFor(GoogleClient c) =>
      OidcProvider.google(clientId: c.clientId, clientSecret: c.clientSecret, issuer: issuers[googleProvider]);

  /// The provider [c] makes; throws [FormatException] when its key isn't a `.p8`.
  OidcProvider appleFor(AppleClient c) => OidcProvider.apple(
        servicesId: c.servicesId,
        key: AppleKey(teamId: c.teamId, keyId: c.keyId, privateKey: readP8(c.key)),
        issuer: issuers[appleProvider],
      );

  /// Turns Google on with [c] (or changes it), as [by] did at [now], and keeps it.
  Future<void> setGoogle(GoogleClient c, {String? by, required int now}) async {
    _requireAttached();
    final provider = googleFor(c);
    await _write({
      ..._doc,
      googleProvider: {'client_id': c.clientId, 'client_secret': c.clientSecret, 'set_at': now, 'set_by': ?by},
    });
    _google = provider;
    _bump(googleProvider);
  }

  /// Turns Apple on with [c] (or changes it), as [by] did at [now], and keeps it. Throws
  /// [FormatException] for a key that isn't a `.p8`.
  Future<void> setApple(AppleClient c, {String? by, required int now}) async {
    _requireAttached();
    final provider = appleFor(c);
    await _write({
      ..._doc,
      appleProvider: {
        'services_id': c.servicesId,
        'team_id': c.teamId,
        'key_id': c.keyId,
        'key': c.key,
        'set_at': now,
        'set_by': ?by,
      },
    });
    _apple = provider;
    _bump(appleProvider);
  }

  /// Turns [provider] off and forgets what it was set up with.
  Future<void> turnOff(String provider) async {
    _requireAttached();
    final next = {..._doc}..remove(provider);
    await _write(next);
    if (provider == googleProvider) _google = null;
    if (provider == appleProvider) _apple = null;
    _bump(provider);
  }

  /// A settings file others can read (copied in by hand, or from a restore on a system without
  /// `chmod`) is made its owner's alone as the host starts; when that fails, the log says so.
  void _ownerOnly() {
    final file = _file;
    if (file == null || Platform.isWindows || !file.existsSync()) return;
    if (file.statSync().mode & 0x3f == 0) return;
    if (restrictToOwner(file.path, warn: _log?.warn)) {
      _log?.warn('${file.path} could be read by other users on this machine; it is its owner\'s alone now.');
    }
  }

  OidcProvider? _googleFrom(Object? entry) {
    if (entry == null) return null;
    final id = entry is Map ? entry['client_id'] : null, secret = entry is Map ? entry['client_secret'] : null;
    if (id is! String || secret is! String || id.isEmpty || secret.isEmpty) {
      _log?.warn('The saved Google sign-in settings can\'t be read, so Google sign-in is off. Set it up again in the app.');
      return null;
    }
    return googleFor(GoogleClient(clientId: id, clientSecret: secret));
  }

  OidcProvider? _appleFrom(Object? entry) {
    if (entry == null) return null;
    final m = entry is Map ? entry : const {};
    final id = m['services_id'], team = m['team_id'], kid = m['key_id'], key = m['key'];
    if (id is String && team is String && kid is String && key is String) {
      try {
        return appleFor(AppleClient(servicesId: id, teamId: team, keyId: kid, key: key));
      } on FormatException {
        // Said below.
      }
    }
    _log?.warn('The saved Apple sign-in settings can\'t be read, so Apple sign-in is off. Set it up again in the app.');
    return null;
  }

  File? get _file => _dir == null ? null : File([_dir!, 'hub', signInFile].join(Platform.pathSeparator));

  Map<String, Object?> _read() {
    final file = _file;
    if (file == null || !file.existsSync()) return const {};
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map) return json.cast<String, Object?>();
    } on Object {
      // Said below.
    }
    _log?.warn('${file.path} can\'t be read, so signing in with Google and Apple is off. Set it up again in the app.');
    return const {};
  }

  /// Keeps [doc]: owner-only from the start (`hub/` 0700, the file 0600 before anything goes in,
  /// then renamed into place), as the host's push key is.
  Future<void> _write(Map<String, Object?> doc) async {
    final file = _file;
    if (file != null) {
      HostState.ownerOnlyDir(file.parent);
      final temp = File('${file.path}.tmp');
      if (temp.existsSync()) temp.deleteSync();
      temp.createSync(exclusive: true);
      HostState.ownerOnlyFile(temp.path);
      temp.writeAsStringSync(jsonEncode({...doc, 'v': 1}), flush: true);
      temp.renameSync(file.path);
    }
    _doc = Map.unmodifiable({...doc}..remove('v'));
  }
}

/// `/api/v1/hub/sign-in`: setting up signing in with Google and Apple from a parent's phone.
///
/// - `GET` says whether each provider is on (when, by whom), and the addresses to register with
///   Google and Apple: every family's on the host, each with its own way back.
/// - `PUT /api/v1/hub/sign-in/google {client_id, client_secret}` and
///   `PUT /api/v1/hub/sign-in/apple {services_id, team_id, key_id, key}` turn one on, or change
///   it, once the provider's discovery document is read and its token endpoint knows the client.
/// - `DELETE /api/v1/hub/sign-in/<provider>` turns it off.
///
/// Only a parent of the host's own family, on their own personal phone, with a request it
/// signs; every answer is the same status, never a client id, a secret or a key.
class HubSignInSetup {
  /// The setup for [hub], checking signed requests with [auth].
  HubSignInSetup(this.hub, this.auth);

  /// Shared hub context.
  final HubContext hub;

  /// Checks the signed requests.
  final DeviceAuth auth;

  /// Adds the routes.
  void register(Routes routes) {
    routes
      ..add('GET', '/api/v1/hub/sign-in', (r, _) => status(r))
      ..add('PUT', '/api/v1/hub/sign-in/<provider>', (r, p) => turnOn(r, p['provider']!))
      ..add('DELETE', '/api/v1/hub/sign-in/<provider>', (r, p) => turnOff(r, p['provider']!));
  }

  HostSignIn? get _settings => hub.host?.signIn;

  /// [c], when it is a parent of the host's own family on their own personal phone. A parent of
  /// another family on the host gets `403 host_family_only` and learns nothing more.
  DeviceRequestCheck _allowed(DeviceRequestCheck c) {
    const message = 'Only a parent\'s own phone can set up signing in with Google or Apple.';
    DeviceAuth.parentOf(c, message: message);
    if (c.device!.mode != DeviceMode.personal) throw ApiError.denied(message);
    final settings = _settings;
    if (settings == null || settings.hostFamily != hub.den.deviceId) {
      throw ApiError(403, 'host_family_only',
          'Signing in with Google or Apple is set up by whoever runs this server, for every family on it.');
    }
    return c;
  }

  /// The family addresses on the host that can sign people in (`https`), the host's own first;
  /// and those that can't.
  ({List<Uri> https, List<Uri> other}) _addresses() {
    final all = hub.host?.familyAddresses ?? [?hub.config.publicUrl];
    return (
      https: [for (final u in all) if (u.isScheme('https') && u.host.isNotEmpty) u],
      other: [for (final u in all) if (!u.isScheme('https') && u.host.isNotEmpty) u],
    );
  }

  Map<String, Object?> _describe() {
    final s = _settings!;
    final (:https, :other) = _addresses();
    Map<String, Object?> one(String provider) {
      final set = s.setOf(provider);
      if (set == null) return {'on': false};
      final by = set.by == null ? null : hub.den.member(set.by!)?.name;
      return {'on': true, 'set_at': set.at, 'set_by': ?by};
    }

    return {
      'google': {
        ...one(googleProvider),
        'redirect_urls': [for (final u in https) urlOf(u, '/auth/oidc/google/callback')],
      },
      'apple': {
        ...one(appleProvider),
        'domains': [for (final u in https) u.hasPort && u.port != 443 ? '${u.host}:${u.port}' : u.host],
        'return_urls': [for (final u in https) urlOf(u, '/auth/oidc/apple/callback')],
      },
      'https': https.isNotEmpty,
      if (other.isNotEmpty) 'without_https': [for (final u in other) u.host],
    };
  }

  /// `GET /api/v1/hub/sign-in`.
  Future<Response> status(Request r) async {
    _allowed(await auth.check(r));
    return jsonResponse(_describe(), headers: const {'cache-control': 'no-store'});
  }

  /// `PUT /api/v1/hub/sign-in/<provider>`. Only over HTTPS (at a trusted proxy that says so) or
  /// from this machine itself: what it carries is a secret.
  Future<Response> turnOn(Request r, String provider) async {
    if (provider != googleProvider && provider != appleProvider) throw ApiError.notFound();
    if (!arrivedOverHttps(r, hub.config.trustedProxies) && !DenHost.local(r)) {
      hub.failed(r);
      throw ApiError(403, 'needs_https',
          'Open Den at its https address to set this up: what you paste here is a secret, and this connection isn\'t encrypted.');
    }
    final signed = await auth.withBody(r, limit: 16 * 1024);
    final c = _allowed(signed.check);
    hub.limit(r, 'sign-in-setup', Limits.signInSetup, message: 'Too many tries. Wait a few minutes, then try again.');
    final json = _object(signed.body);
    String text(String name) => (json[name] is String ? json[name] as String : '').trim();
    final (:https, other: _) = _addresses();
    if (https.isEmpty) {
      throw ApiError(409, 'needs_https',
          'Signing in with Google or Apple needs the hub at an https address, where they send people back. '
          'Whoever set up the hub can give it one; it\'s in the hub\'s hosting guide.');
    }
    final s = _settings!;
    final now = hub.now();
    final back = urlOf(https.first, '/auth/oidc/$provider/callback');
    final actor = c.actor!;
    final wasOn = s.isOn(provider);
    if (provider == googleProvider) {
      final client = GoogleClient(clientId: text('client_id'), clientSecret: text('client_secret'));
      final idProblem = googleClientIdProblem(client.clientId);
      if (idProblem != null) throw ApiError.invalid(idProblem, field: 'client_id');
      final secretProblem = googleSecretProblem(client.clientSecret);
      if (secretProblem != null) throw ApiError.invalid(secretProblem, field: 'client_secret');
      await _check(s.googleFor(client), back, now);
      _stillHost(s);
      await s.setGoogle(client, by: actor.id, now: now);
    } else {
      final client = AppleClient(
        servicesId: text('services_id'),
        teamId: text('team_id').toUpperCase(),
        keyId: text('key_id').toUpperCase(),
        key: text('key'),
      );
      final problems = {
        'services_id': appleServicesIdProblem(client.servicesId),
        'team_id': appleTenProblem(client.teamId, 'Team ID'),
        'key_id': appleTenProblem(client.keyId, 'Key ID'),
      };
      for (final e in problems.entries) {
        if (e.value != null) throw ApiError.invalid(e.value!, field: e.key);
      }
      if (client.key.isEmpty) throw ApiError.invalid('Choose the .p8 file Apple gave you, or paste what it holds.', field: 'key');
      final OidcProvider candidate;
      try {
        candidate = s.appleFor(client);
      } on FormatException catch (e) {
        throw ApiError.invalid('${e.message}. Choose the .p8 file Apple gave you for Sign in with Apple.', field: 'key');
      }
      await _check(candidate, back, now);
      _stillHost(s);
      await s.setApple(client, by: actor.id, now: now);
    }
    final name = provider == googleProvider ? 'Google' : 'Apple';
    hub.log.info('${actor.name} ${wasOn ? 'changed' : 'turned on'} signing in with $name');
    return jsonResponse(_describe(), headers: const {'cache-control': 'no-store'});
  }

  /// Throws unless this family is still the host's own, attached: it may have stopped while the
  /// provider was asked, and then nothing may be kept.
  void _stillHost(HostSignIn s) {
    if (s.hostFamily != hub.den.deviceId) {
      throw ApiError(503, 'not_ready', 'The hub is restarting, so nothing changed. Try again in a minute.', details: {'retry': true});
    }
  }

  /// Reads [p]'s discovery document and asks its token endpoint whether it knows the client;
  /// throws what to tell the parent when either fails.
  Future<void> _check(OidcProvider p, String redirectUri, int now) async {
    final ClientCheck answer;
    try {
      await p.endpoints(hub.fetch, now);
      answer = await p.checkClient(hub.fetch, redirectUri: redirectUri, now: now);
    } on OidcRefused catch (e) {
      hub.log.warn('Couldn\'t check the ${p.name} sign-in settings: ${e.reason}');
      throw ApiError(502, 'provider_unreachable', 'Den couldn\'t reach ${p.name} to check that. Nothing changed. Try again in a few minutes.',
          details: {'retry': true});
    }
    switch (answer) {
      case ClientCheck.known:
        return;
      case ClientCheck.unknown:
        throw p.id == googleProvider
            ? ApiError.invalid('Google doesn\'t know that client ID and secret together. Copy both again from the client\'s page.',
                field: 'client_id')
            : ApiError.invalid('Apple didn\'t take that Services ID, Team ID, Key ID and key together. Check each one, and that '
                'the key is for Sign in with Apple.', field: 'services_id');
      case ClientCheck.unconfirmed:
        throw p.id == googleProvider
            ? ApiError.invalid('Google didn\'t confirm that client ID and secret, so nothing changed. Check that the addresses above '
                'are added to the client, then try again in a few minutes.', field: 'client_id')
            : ApiError.invalid('Apple didn\'t confirm that Services ID and key, so nothing changed. Check that the addresses above '
                'are added to the Services ID, then try again in a few minutes.', field: 'services_id');
      case ClientCheck.wrongKind:
        throw p.id == googleProvider
            ? ApiError.invalid('That client can\'t sign in on a website. Make one of the type Web application.', field: 'client_id')
            : ApiError.invalid('That Services ID isn\'t set up for Sign in with Apple on a website. Turn it on and configure it.',
                field: 'services_id');
    }
  }

  /// `DELETE /api/v1/hub/sign-in/<provider>`.
  Future<Response> turnOff(Request r, String provider) async {
    if (provider != googleProvider && provider != appleProvider) throw ApiError.notFound();
    final c = _allowed(await auth.check(r));
    final s = _settings!;
    _stillHost(s);
    if (s.isOn(provider)) {
      await s.turnOff(provider);
      hub.log.info('${c.actor!.name} turned off signing in with ${provider == googleProvider ? 'Google' : 'Apple'}');
    }
    return jsonResponse(_describe(), headers: const {'cache-control': 'no-store'});
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
}
