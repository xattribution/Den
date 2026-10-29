import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:den_net/io.dart';
import 'package:http/http.dart' as http_client;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'access.dart';
import 'config.dart';
import 'device_auth.dart';
import 'edge.dart';
import 'host_state.dart';
import 'http_util.dart';
import 'hub.dart';
import 'invites.dart';
import 'log.dart';
import 'net_guard.dart';
import 'recovery.dart';
import 'tenant_router.dart';
import 'web.dart';

/// A log the host opens while it runs ([HostConfig.openLog]): its engine, how its hub runs, and
/// how to close it again (the engine, and the data directory's lock).
typedef HostedTenant = ({Den den, HubConfig config, Future<void> Function() close});

/// How a Den host runs: what every family on it shares. Each family's own settings are its
/// [HubConfig].
class HostConfig {
  /// Creates the host's configuration.
  const HostConfig({
    this.port = defaultHubPort,
    this.host,
    this.dataDir,
    this.webDir,
    this.trustedProxies = const [],
    this.contentSecurityPolicy,
    this.log,
    this.httpClient,
    this.fetchAllow = const [],
    this.peerHubs = const [],
    this.resolver,
    this.fetchClient,
    this.openLog,
    this.createLog,
    this.deleteLog,
    this.single = false,
    this.expected = const [],
    this.retryInterval = const Duration(seconds: 30),
  });

  /// The host-wide part of [config], for a host serving that one hub ([DenHub.start]).
  factory HostConfig.of(HubConfig config) => HostConfig(
        single: true,
        port: config.port,
        host: config.host,
        webDir: config.webDir,
        trustedProxies: config.trustedProxies,
        contentSecurityPolicy: config.contentSecurityPolicy,
        log: config.log,
        httpClient: config.httpClient,
        fetchAllow: config.fetchAllow,
        peerHubs: config.peerHubs,
        resolver: config.resolver,
        fetchClient: config.fetchClient,
      );

  /// TCP port for every family's HTTP, sync and MCP; 0 picks a free one.
  final int port;

  /// Address to bind; default every IPv4 interface.
  final Object? host;

  /// The host's data directory: the first family's data in it as a hub's always was, each other
  /// log in `logs/<id>/`, the host's own state in `host/`. Null keeps the host's state in memory.
  final String? dataDir;

  /// The web app, served to every family's address alike.
  final String? webDir;

  /// Reverse proxies whose `X-Forwarded-*` headers count (`DEN_TRUSTED_PROXIES`).
  final List<IpNetwork> trustedProxies;

  /// Replaces the web app's Content-Security-Policy (`DEN_CSP`).
  final String? contentSecurityPolicy;

  /// Where the host logs.
  final HubLog? log;

  /// Outgoing HTTP to what the operator configured; null makes one.
  final http_client.Client? httpClient;

  /// Private networks addresses callers give may be fetched from (`DEN_FETCH_ALLOW`).
  final List<IpNetwork> fetchAllow;

  /// Other families' hubs on this server in their own containers (`DEN_PEER_HUBS`), whose
  /// names may lead to loopback. The host's own families' addresses always may.
  final List<Uri> peerHubs;

  /// Looks names up for NetGuard; null is the system's.
  final HostResolver? resolver;

  /// Replaces NetGuard's client altogether (tests).
  final http_client.Client? fetchClient;

  /// Opens a log in `logs/` that the host takes on while it runs (`den_hub adopt`, or one that
  /// was taken off and added again). Null: the host can't take on logs while it runs.
  final Future<HostedTenant> Function(HostedLog log)? openLog;

  /// Makes a fresh log for a new family (`den_hub add-family`), ready for its first parent's
  /// phone. Null: as [openLog].
  final Future<HostedTenant> Function(HostedLog log)? createLog;

  /// Deletes a log's data for good (`den_hub remove-family --delete-data`), once the host has
  /// stopped serving it; throws [StateError] when something else (a backup) has it open. Null:
  /// the host can't delete families' data while it runs.
  final Future<void> Function(HostedLog log)? deleteLog;

  /// Whether the host is configured for one family: as long as it has never had another (none in
  /// `host.json`, served, taken off or deleted), that family answers at any address, as a hub
  /// always has ([DenHub.start], and `den_hub serve` on a data directory with one family).
  /// Otherwise each family answers at its own address only, and an address that is none of
  /// theirs gets no family.
  final bool single;

  /// The addresses the host serves besides those `host.json` lists (the first family's public
  /// URL's name). Until the family at one of them is attached, requests to it are answered `503`
  /// with `Retry-After`, never by another family.
  final List<String> expected;

  /// How often the host tries again to open a family in `host.json` that didn't open.
  final Duration retryInterval;
}

/// The Den host: one process serving several families' logs (docs/hosting.md, "One host for
/// several families"). It owns the HTTP server, admission and rate limits, the web app,
/// NetGuard and the outgoing client, and what is host-wide (the families' addresses, every Web
/// Push key); each family is a [DenHub] (a tenant) with its own engine, sync node, keys, state
/// and services, started in their own guarded zones.
///
/// Each request goes to the one family it is for ([TenantRouter], docs/hub-api.md, "One host,
/// several families"), and that family checks whatever it carries against its own records:
///
/// | Request | Goes to |
/// | --- | --- |
/// | `/ws` | the family the hello names (read before any session answers); a hello naming none, the address's |
/// | signed by a device | the hub `X-Den-Hub` names, once the signature checks out there from the headers; else the address's family |
/// | a bearer token | the address's family, else the one whose token it is |
/// | `/ics/<secret>/…` | the address's family, else the one whose link it is |
/// | invite words, recovery codes, link codes, `den_hub recover` | the one family that keeps them (unique per host) |
/// | a setup code | the address's family |
/// | an invite grant | the hub it names |
/// | everything else | the address's family |
///
/// "The address's family" is the family whose public URL names the request's host; on a host
/// configured for one family ([HostConfig.single]), that family whatever the address. With
/// several, a request that names no family and comes to no family's address gets none: fail
/// closed. An address the host is configured to serve whose family isn't attached (it is
/// starting, or didn't open and is tried again) gets `503` with `Retry-After`. The host's own
/// `/health` fails while it starts, until every family has had its first try at opening; after
/// that it answers `200`, saying how many families aren't open (`den_hub families` says which,
/// and why).
class DenHost implements HostLink {
  DenHost._(this.config, this.state, this.log);

  /// How the host runs.
  final HostConfig config;

  /// The host's own state: which logs it serves, at which addresses.
  final HostState state;

  /// Where the host logs.
  final HubLog log;

  @override
  final RateLimiter limits = RateLimiter();

  /// Wrong invite words: one client's count is the host's, and the count for everyone together
  /// grows with the families on it, so a few clients can't keep every family from joining.
  @override
  late final WrongGuesses inviteGuesses = WrongGuesses(
      perClient: HubInvites.maxWrong, ceiling: HubInvites.wrongCeiling, window: HubInvites.wrongWindow, scale: _families);

  /// Wrong recovery codes, counted as [inviteGuesses] are.
  @override
  late final WrongGuesses recoveryGuesses = WrongGuesses(
      perClient: HubRecovery.maxWrong, ceiling: HubRecovery.wrongCeiling, window: HubRecovery.wrongWindow, scale: _families);

  int _families() => max(1, _tenants.length);

  @override
  late final http_client.Client http;

  @override
  late final http_client.Client fetch;

  /// The outgoing client for the calendar feeds of the hub [hubDevice]: [fetch], except that
  /// reading another family's calendar link on this host is answered in this process. Only the
  /// feed service has it ([HubContext.feedFetch]); everything else a hub fetches goes through
  /// [fetch].
  http_client.Client fetchFor(String hubDevice) => _OtherFamilies(this, hubDevice);

  late final Handler _handler;

  final List<DenHub> _tenants = [];
  final Map<DenHub, HostedTenant> _opened = {};
  final Map<DenHub, String> _ids = {};
  /// Picks the family each request is for.
  late final TenantRouter<DenHub> router = TenantRouter(() => List.of(_tenants), single: () => single);

  /// Whether the host answers as one family at any address: configured for one family, and it has
  /// never had another ([HostState.several]). A host that had several never goes back, so an
  /// address a family was taken off never reaches the first family.
  bool get single => config.single && !state.several;

  Timer? _retry;
  bool _settled = false;
  final Map<String, String> _whyNot = {};
  final Map<String, int> _sockets = {};
  final Set<String> _warnedProxies = {};
  late final bool _ownsHttp;
  HttpServer? _server;
  Handler? _web;
  String? _cliSecret;
  Future<void> _busy = Future.value();
  bool _stopped = false;

  /// The request context key the host sets on a request it already counted against the
  /// anonymous budget, so the family it goes to doesn't count it again.
  static const String admittedKey = 'den.host.admitted';

  /// The header `den_hub` shows the running host its secret in ([hostCliFile]).
  static const String secretHeader = 'x-den-host-secret';

  /// Paths the families answer; everything else is the web app.
  static const Set<String> reserved = {'api', 'mcp', 'oauth', 'ics', '.well-known', 'ws', 'health'};

  /// Starts serving, with no families yet ([add] them).
  static Future<DenHost> start(HostConfig config) async {
    final log = config.log ?? HubLog();
    final host = DenHost._(config, HostState(config.dataDir), log);
    host._ownsHttp = config.httpClient == null;
    host.http = config.httpClient ?? http_client.Client();
    host.fetch = config.fetchClient ??
        NetGuard(
          resolve: config.resolver,
          allow: config.fetchAllow,
          hubs: config.peerHubs,
          moreHubs: () => [for (final t in host._tenants) ?t.config.publicUrl],
        ).client();
    host._cliSecret = host.state.writeCliSecret();
    host.state.dropKeyring();
    host._web = webAppHandler(config.webDir, policy: host._webPolicy);
    final pipeline = host._handler = const Pipeline().addMiddleware(host._headers).addMiddleware(host._errors).addHandler(host._route);
    final server = host._server = await HttpServer.bind(config.host ?? InternetAddress.anyIPv4, config.port);
    server.idleTimeout = const Duration(seconds: 120);
    shelf_io.serveRequests(_screened(server), pipeline);
    return host;
  }

  /// [requests] without those shelf can't read (a `Host` or `X-Forwarded-Proto` that makes no
  /// address, say), which are answered `400` here instead of shelf's `500`.
  static Stream<HttpRequest> _screened(Stream<HttpRequest> requests) => requests.where((request) {
        try {
          request.requestedUri;
          return true;
        } on Object {
          final response = request.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.text
            ..write('Bad Request');
          unawaited(response.close().then((_) {}, onError: (Object _) {}));
          return false;
        }
      });

  /// The families on the host, the first first.
  List<DenHub> get tenants => List.unmodifiable(_tenants);

  /// The port being served.
  int get port => _server!.port;

  /// `http://127.0.0.1:<port>`.
  Uri get localUrl => Uri.parse('http://127.0.0.1:$port');

  /// The id of [tenant]'s log in `logs/`, or null for the first family's.
  String? idOf(DenHub tenant) => _ids[tenant];

  /// Starts serving a family over [den] (already open) as [config] says: its own engine, state,
  /// services and address. [id] is its log's directory name in `logs/` (null for the first
  /// family's, in the data directory itself). [onClosed] runs once the family has stopped (the
  /// caller closing its engine). Throws [StateError] when another family on the host already
  /// has its hub device, its family or its address: two families can never share one.
  Future<DenHub> add(Den den, HubConfig config, {String? id, Future<void> Function()? onClosed}) async {
    if (_stopped) throw StateError('The host has stopped');
    final name = normalizeHostname(config.publicUrl?.host);
    for (final t in _tenants) {
      if (t.den.deviceId == den.deviceId) throw StateError('That hub is on this host already');
      if (den.familyId != null && t.den.familyId == den.familyId) throw StateError('That family is on this host already');
      if (name != null && t.hostnames.contains(name)) throw StateError('$name is another family\'s address on this host');
    }
    final tenant = await DenHub.tenantOf(this, den, config);
    _tenants.add(tenant);
    if (id != null) _ids[tenant] = id;
    if (id == null) state.notePrimary(config.publicUrl);
    if (onClosed != null) _opened[tenant] = (den: den, config: config, close: onClosed);
    return tenant;
  }

  /// Stops serving [tenant]. Its data stays where it is.
  Future<void> remove(DenHub tenant) async {
    if (!_tenants.contains(tenant)) return;
    await tenant.stop();
  }

  /// Called by a tenant as it stops: no request goes to it any more.
  void detach(DenHub tenant) {
    _tenants.remove(tenant);
    _ids.remove(tenant);
  }

  // ------------------------------------------------------------------ HostLink

  @override
  bool inviteTaken(String key) => _tenants.any((t) => t.invites.holds(key));

  @override
  bool recoveryCodeTaken(String hash) => _tenants.any((t) => t.recovery.holdsCode(hash));

  @override
  bool setupCodeTaken(String code) => _tenants.any((t) => t.waitsForSetupCode(code));

  @override
  bool familyElsewhere(String familyId, String hubDevice) =>
      _tenants.any((t) => t.den.familyId == familyId && t.den.deviceId != hubDevice);

  @override
  String admitSocket(Request request) {
    _limit(request, 'sockets', Limits.sockets, message: 'Too many connections from here. Wait a minute.');
    final key = _clientKey(request);
    if ((_sockets[key] ?? 0) >= Limits.openSockets) {
      throw ApiError.rateLimited(30, 'Too many connections from here. Close some and try again.');
    }
    return key;
  }

  // ------------------------------------------------------------------ limits

  String _clientKey(Request request) => requestClientKey(request, config.trustedProxies);

  void _limit(Request request, String name, Rate rate, {String? message}) {
    final key = _clientKey(request);
    if (limits.allow(name, key, rate)) return;
    final wait = limits.retryAfter(name, key, rate);
    throw message == null ? ApiError.rateLimited(wait) : ApiError.rateLimited(wait, message);
  }

  void _failed(Request request) => limits.allow('failures', _clientKey(request), Limits.failures);

  void _checkFailures(Request request) {
    final key = _clientKey(request);
    if (limits.exhausted('failures', key, Limits.failures)) {
      throw ApiError.rateLimited(limits.retryAfter('failures', key, Limits.failures));
    }
  }

  /// Headers a reverse proxy or CDN adds, besides every `X-Forwarded-*`; a request with any of
  /// them didn't come from this machine itself, whatever its peer address.
  static const Set<String> _proxyHeaders = {
    'forwarded',
    'via',
    'x-real-ip',
    'x-client-ip',
    'x-cluster-client-ip',
    'x-original-forwarded-for',
    'cf-connecting-ip',
    'cf-connecting-ipv6',
    'true-client-ip',
    'fastly-client-ip',
  };

  /// Whether [request] came from this machine itself, not through a proxy: from loopback, with
  /// no header any proxy adds.
  static bool local(Request request) {
    final peer = peerAddress(request);
    if (peer == null || !peer.isLoopback) return false;
    for (final name in request.headers.keys) {
      final n = name.toLowerCase();
      if (n.startsWith('x-forwarded-') || _proxyHeaders.contains(n)) return false;
    }
    return true;
  }

  /// The anonymous budget, for a request the host answers or reads itself.
  Request _anonymous(Request request) {
    if (request.headers.containsKey('x-forwarded-for') && !viaTrustedProxy(request, config.trustedProxies)) {
      warnUntrustedProxy(request);
    }
    if (!local(request)) _limit(request, 'anonymous', Limits.anonymous);
    return request.change(context: {admittedKey: true});
  }

  /// Says once per proxy that it sends `X-Forwarded-For` without being trusted.
  void warnUntrustedProxy(Request request) {
    final peer = peerAddress(request)?.address;
    if (peer == null || _warnedProxies.length >= 16 || !_warnedProxies.add(peer)) return;
    log.warn('Requests from $peer carry X-Forwarded-For, but DEN_TRUSTED_PROXIES doesn\'t list $peer, so the hub '
        'ignores the header and limits everyone behind that proxy as one client. List the proxy to fix that.');
  }

  // ------------------------------------------------------------------ the pipeline

  String? _hostname(Request request) => requestHostname(request, config.trustedProxies);

  /// The base URL [request] came to, by the address's family's public URL.
  Uri _base(Request request) =>
      requestBase(request, router.forHostname(_hostname(request))?.config.publicUrl, trusted: config.trustedProxies);

  String _webPolicy(Request request, List<String> scriptHashes) {
    final custom = config.contentSecurityPolicy;
    if (custom != null && custom.trim().isNotEmpty) return custom;
    final base = _base(request);
    return webAppPolicy(connect: '${base.scheme == 'https' ? 'wss' : 'ws'}://${base.authority}', scriptHashes: scriptHashes);
  }

  /// Security headers on every answer: no content sniffing, no referrer, HSTS when the request
  /// came over HTTPS, no framing and same-origin opener isolation for pages, and a CSP that
  /// allows nothing for JSON.
  Handler _headers(Handler inner) => (Request request) async {
        final response = await inner(request);
        final type = response.headers['content-type'] ?? '';
        final html = type.startsWith('text/html');
        return response.change(headers: {
          'x-content-type-options': 'nosniff',
          'referrer-policy': 'no-referrer',
          if (_base(request).scheme == 'https') 'strict-transport-security': 'max-age=31536000',
          if (html) 'x-frame-options': 'DENY',
          if (html) 'cross-origin-opener-policy': 'same-origin',
          if (type.startsWith('application/json') && !response.headers.containsKey('content-security-policy'))
            'content-security-policy': "default-src 'none'; frame-ancestors 'none'",
        });
      };

  Handler _errors(Handler inner) => (Request request) async {
        final started = DateTime.now();
        Response response;
        try {
          response = await inner(request);
        } on ApiError catch (e) {
          response = e.toResponse();
        } on HijackException {
          rethrow;
        } on Object catch (e, st) {
          log.error('${request.method} ${_safePath(request)} failed: ${describeError(e, st)}');
          response = ApiError(500, 'internal', 'Something went wrong on the hub.').toResponse();
        }
        log.debug('${request.method} ${_safePath(request)} ${response.statusCode} ${DateTime.now().difference(started).inMilliseconds}ms');
        return response;
      };

  /// The request path with secrets in it (feed tokens, link slots) hidden and no query.
  static String _safePath(Request request) {
    final segments = request.url.pathSegments;
    final out = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final hide = i > 0 && (segments[i - 1] == 'ics' || segments[i - 1] == 'link');
      out.add(hide ? '…' : segments[i]);
    }
    return '/${out.join('/')}';
  }

  /// No family is at the address, and nothing in the request names one.
  static ApiError _noFamily() => ApiError(404, 'no_family', 'No family\'s Den is at this address.');

  /// The addresses the host is configured to serve: [HostConfig.expected] and every family
  /// `host.json` lists.
  Set<String> get _configured => {
        for (final e in config.expected) ?normalizeHostname(e),
        for (final l in state.logs) ?l.hostname,
      };

  /// The configured addresses whose family isn't attached now (starting, or tried again).
  List<String> get unavailable => [for (final a in _configured) if (router.mapped(a) == null) a];

  /// Whether a request to [hostname] waits for its family: the address is one the host is
  /// configured to serve and its family isn't attached; or the host is configured for one family
  /// that isn't attached yet.
  bool awaiting(String? hostname) {
    if (single && _tenants.isEmpty) return true;
    if (hostname == null || router.mapped(hostname) != null) return false;
    return _configured.contains(hostname);
  }

  FutureOr<Response> _route(Request request) async {
    final segments = request.url.pathSegments.where((s) => s.isNotEmpty).toList();
    final first = segments.isEmpty ? '' : segments.first;
    if (request.url.path == 'ws') return _ws(request);
    if (!reserved.contains(first)) {
      final admitted = _anonymous(request);
      final web = _web;
      if (web != null) return web(admitted);
      throw ApiError.notFound();
    }
    if (segments.length >= 3 && segments[0] == 'api' && segments[1] == 'v1' && segments[2] == 'host') return _admin(request, segments);
    final hostname = _hostname(request);
    final headers = request.headers;
    final method = request.method;

    // Signed by a device and naming its hub: that hub, once the signature checks out there from
    // the headers alone (the body hash it covers is in X-Den-Body-SHA256). A signature that
    // doesn't, or names a hub that isn't here, goes by address like any request, so made-up
    // headers reach nothing an address doesn't and say nothing about which hubs are here.
    final named = headers[DeviceRequest.hubHeader];
    final signed = headers[DeviceRequest.device] != null && headers[DeviceRequest.signature] != null;
    if (signed && named != null) {
      final tenant = router.forHub(named);
      if (tenant != null && await tenant.verifiesHeaders(request)) {
        return tenant.handle(request.change(context: {DeviceAuth.verifiedHeaders: true}));
      }
    }

    // An address the host serves whose family isn't here yet: it is starting (or didn't open,
    // and is tried again). Never another family's answer, and never a refusal a client could
    // take for good: a calendar's subscribers keep their copies through a 503.
    if (awaiting(hostname)) throw ApiError.starting();

    // A calendar link: the address's family, else the one whose link it is.
    if (first == 'ics' && segments.length == 3) {
      final secret = segments[1];
      final tenant = router.forCredential(hostname, (t) => t.holdsFeed(secret));
      if (tenant != null) return tenant.handle(request);
      _checkFailures(request);
      _failed(request);
      throw _noFamily();
    }

    // Signed, without a hub that checked it: the address's family, which checks it.
    if (signed) {
      final tenant = router.forHostname(hostname);
      if (tenant != null) return tenant.handle(request);
      _checkFailures(request);
      _failed(request);
      throw ApiError.unauthorized('This needs a request signed by a device in this family.');
    }

    // A bearer token: the address's family, else the one whose token it is.
    final token = bearerToken(headers['authorization']);
    if (token != null) {
      final tenant = router.forCredential(hostname, (t) => t.holdsToken(token));
      if (tenant != null) return tenant.handle(request);
      _checkFailures(request);
      _failed(request);
      throw ApiError.unauthorized();
    }

    final path = segments.join('/');
    // Invite words and recovery codes: unique per host, found in whichever family keeps them.
    if (method == 'POST' && path == 'api/v1/invites/redeem') {
      return HubInvites.redeemAcross(_anonymous(request), [for (final t in _tenants) t.invites]);
    }
    if (method == 'POST' && path == 'api/v1/recovery/redeem') {
      return HubRecovery.redeemAcross(_anonymous(request), [for (final t in _tenants) t.recovery]);
    }
    // `den_hub recover` on this machine: the family whose secret it shows.
    if (method == 'POST' && path == 'api/v1/recovery/tickets') {
      final given = headers[recoverySecretHeader];
      final tenant = router.forBook(hostname, (t) => t.recovery.cliSecretIs(given));
      if (tenant != null) return tenant.handle(request);
      _failed(request);
      throw ApiError.denied('Only den_hub recover, on the hub\'s own machine, can make a recovery code.');
    }
    // A browser waiting to be linked: the family that gave it its link code.
    if (segments.length == 4 && path.startsWith('api/v1/link/') && segments[3] != 'window') {
      final tenant = router.forBook(hostname, (t) => t.holdsLinkSlot(segments[3]));
      if (tenant != null) return tenant.handle(request);
      _checkFailures(request);
      _failed(request);
      throw ApiError.notFound(type: 'link', message: 'That link code expired. Show a new one.');
    }
    // An invite grant: the hub it names, which checks the grant is its family's.
    if (method == 'POST' && path == 'api/v1/invites') {
      final admitted = _anonymous(request);
      final body = await readBodyBytes(admitted);
      final again = admitted.change(body: body);
      final named = _grantHub(body);
      final tenant = (named == null ? null : router.forHub(named)) ?? router.forHostname(hostname);
      if (tenant != null) return tenant.handle(again);
      throw _noFamily();
    }

    // Everything else, a setup code included: the address's family.
    final tenant = router.forHostname(hostname);
    if (tenant != null) return tenant.handle(request);
    if (path == 'health') {
      _anonymous(request);
      // Starting: fails until every family has had its first try. After that the host is up
      // (its other families are served), and says how many families aren't open.
      final waiting = unavailable.length;
      final starting = waiting > 0 && !_settled;
      return jsonResponse({
        'ok': !starting,
        'api': 1,
        'ready': waiting == 0 && _tenants.isNotEmpty && _tenants.every((t) => t.ready),
        if (waiting > 0) 'waiting': waiting,
      }, status: starting ? 503 : 200, headers: {if (starting) 'retry-after': '10'});
    }
    _anonymous(request);
    throw _noFamily();
  }

  /// The hub an invite grant's invite names as its inviting device, or null.
  static String? _grantHub(List<int> body) {
    try {
      final json = jsonDecode(utf8.decode(body));
      final url = json is Map ? json['invite'] : null;
      return url is String ? Invite.decode(url).inviterDevice : null;
    } on Object {
      return null;
    }
  }

  /// `GET /ws`: device sync. The host reads each connection's hello before any family answers
  /// it, and hands the connection to the family it names (a hello naming none: the address's),
  /// whose sync node then checks the hello in full and refuses any family but its own. A hello
  /// naming no family here is closed.
  FutureOr<Response> _ws(Request request) {
    final key = admitSocket(request);
    final hostname = _hostname(request);
    return helloWebSocketHandler(
      (hello) {
        final family = hello.family;
        final tenant = family != null
            ? router.forFamily(family, hostname: hostname)
            : (awaiting(hostname) ? null : router.forHostname(hostname));
        if (tenant == null || _stopped) {
          unawaited(hello.channel.sink.close().then((_) {}, onError: (Object _) {}));
          return;
        }
        // Devices that aren't approved yet get places per client, so no one address can keep
        // everyone else from joining or recovering.
        unawaited(tenant.serveSocket(hello.channel, client: key));
      },
      onSocket: (socket) {
        _sockets[key] = (_sockets[key] ?? 0) + 1;
        var open = true;
        void closed() {
          if (!open) return;
          open = false;
          final left = (_sockets[key] ?? 1) - 1;
          if (left <= 0) {
            _sockets.remove(key);
          } else {
            _sockets[key] = left;
          }
        }

        unawaited(socket.sink.done.then((_) => closed(), onError: (Object _) => closed()));
      },
      maxMessageBytes: maxSyncSocketMessageBytes,
      pingInterval: const Duration(seconds: 30),
    )(request);
  }

  // ------------------------------------------------------------------ the command line

  /// `/api/v1/host/...`: what `den_hub add-family`, `adopt`, `remove-family` and `families` ask
  /// the running host, only from this machine and only with the secret it left in
  /// [hostCliFile].
  Future<Response> _admin(Request request, List<String> segments) async {
    final secret = _cliSecret;
    final given = request.headers[secretHeader]?.trim();
    if (secret == null || given == null || !local(request) || !_same(given, secret)) {
      _failed(request);
      throw ApiError.denied('Only den_hub, on the host\'s own machine, can do that.');
    }
    final rest = segments.skip(3).toList();
    final method = request.method;
    if (rest.isEmpty && method == 'GET') {
      return jsonResponse({
        'families': [for (final t in _tenants) _describe(t)],
        'waiting': [
          for (final l in _missing)
            {'id': l.id, 'public_url': l.publicUrl?.toString(), 'error': _whyNot[l.id], 'retry_seconds': config.retryInterval.inSeconds},
        ],
      });
    }
    if (rest.length == 1 && rest.first == 'families' && method == 'POST') {
      final json = await readJsonObject(request, required: true);
      return _serial(() => _addFamily(json));
    }
    if (rest.length == 1 && rest.first == 'logs' && method == 'POST') {
      final json = await readJsonObject(request, required: true);
      return _serial(() => _takeOn(json));
    }
    if (rest.length == 2 && rest.first == 'families' && method == 'DELETE') {
      final delete = request.url.queryParameters['delete_data'] == '1';
      return _serial(() => _removeFamily(rest[1], delete: delete));
    }
    throw ApiError.notFound();
  }

  Future<T> _serial<T>(Future<T> Function() body) {
    final run = _busy.then((_) => body());
    _busy = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Map<String, Object?> _describe(DenHub t) => {
        'id': _ids[t],
        'first': !_ids.containsKey(t),
        'public_url': t.config.publicUrl?.toString(),
        'device': t.den.deviceId,
        'family': t.den.familyId,
        'family_name': t.ready ? t.den.family?.name : null,
        'ready': t.ready,
        'stage': t.setupStage.name,
        'setup_code': t.setupCode,
      };

  static Uri? _publicUrl(Object? text) {
    if (text is! String || text.isEmpty || text.length > 300) return null;
    final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http')) || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
    return Uri(scheme: uri.scheme, host: uri.host.toLowerCase(), port: uri.hasPort ? uri.port : null);
  }

  /// Throws `409 conflict` when [url]'s name is a family's on this host: one attached, the
  /// first family's, or any family `host.json` lists, attached now or not.
  void _checkAddress(Uri url) {
    final name = normalizeHostname(url.host);
    if (name == null) throw ApiError.invalid('That isn\'t an address.', field: 'public_url');
    if (_tenants.any((t) => t.hostnames.contains(name)) ||
        _configured.contains(name) ||
        (state.primaryUrl != null && normalizeHostname(state.primaryUrl!.host) == name)) {
      throw ApiError(409, 'conflict', '$name is a family\'s address on this host already.');
    }
  }

  /// `POST /api/v1/host/families {public_url, id?}`: a new family at that address, ready for its
  /// first parent's phone (the answer has the setup code). An address a family was taken off
  /// brings that family back; when more than one was taken off it, `id` says which.
  Future<Response> _addFamily(Map<String, Object?> json) async {
    final url = _publicUrl(json['public_url']);
    if (url == null) throw ApiError.invalid('"public_url" must be an address like https://den-smith.example.com.', field: 'public_url');
    _checkAddress(url);
    final id = json['id'];
    // A family taken off whose data was deleted by hand isn't one to bring back.
    for (final l in state.removedAt(url.host)) {
      final dir = state.dirOf(l.id);
      if (dir != null && !Directory(dir).existsSync()) state.forget(l.id);
    }
    final gone = state.removedAt(url.host);
    if (id != null && (id is! String || !gone.any((l) => l.id == id))) {
      throw ApiError.invalid('No family taken off ${url.host} has that id.', field: 'id');
    }
    if (id == null && gone.length > 1) {
      throw ApiError(409, 'ambiguous',
          'More than one family was taken off ${url.host} (${gone.map((l) => l.id).join(', ')}): say which with --id.',
          details: {'ids': [for (final l in gone) l.id]});
    }
    final previous = id == null ? gone.firstOrNull : gone.firstWhere((l) => l.id == id);
    if (previous != null) {
      final back = previous.copyWith(removed: false);
      final tenant = await _open(back, fresh: false);
      state.put(back);
      log.info('Serving ${url.host} again');
      return jsonResponse(_describe(tenant), status: 201);
    }
    final made = HostedLog(id: HostedLog.newId(), publicUrl: url, added: DateTime.now().toUtc().millisecondsSinceEpoch);
    final tenant = await _open(made, fresh: true);
    state.put(made);
    log.info('Added a family at ${url.host}');
    return jsonResponse(_describe(tenant), status: 201);
  }

  /// `POST /api/v1/host/logs {id, public_url, adopted_from}`: starts serving a hub that
  /// `den_hub adopt` copied into `logs/<id>/`, keys and all, so its phones keep syncing.
  Future<Response> _takeOn(Map<String, Object?> json) async {
    final id = json['id'];
    if (id is! String || !HostedLog.validId(id)) throw ApiError.invalid('"id" isn\'t a log\'s id.', field: 'id');
    if (_ids.containsValue(id)) throw ApiError(409, 'conflict', 'The host serves $id already.');
    final url = json['public_url'] == null ? null : _publicUrl(json['public_url']);
    if (json['public_url'] != null && url == null) throw ApiError.invalid('That isn\'t an address.', field: 'public_url');
    if (url != null) _checkAddress(url);
    final from = json['adopted_from'];
    final log = HostedLog(
      id: id,
      publicUrl: url,
      added: DateTime.now().toUtc().millisecondsSinceEpoch,
      adoptedFrom: from is String ? from : null,
    );
    final tenant = await _open(log, fresh: false);
    state.put(log);
    this.log.info('Took on ${url?.host ?? id}');
    return jsonResponse(_describe(tenant), status: 201);
  }

  Future<DenHub> _open(HostedLog log, {required bool fresh}) async {
    final opener = fresh ? config.createLog : config.openLog;
    if (opener == null) throw ApiError(501, 'unavailable', 'This host can\'t take on families while it runs. Stop it first.');
    final HostedTenant opened;
    try {
      opened = await opener(log);
    } on StateError catch (e) {
      // Its data is in use (a backup), or isn't there: say so, not "something went wrong".
      throw ApiError(409, 'cannot_open', e.message);
    }
    try {
      return await add(opened.den, opened.config, id: log.id, onClosed: opened.close);
    } on StateError catch (e) {
      await opened.close();
      throw ApiError(409, 'conflict', e.message);
    } catch (_) {
      await opened.close();
      rethrow;
    }
  }

  /// `DELETE /api/v1/host/families/<id or address>[?delete_data=1]`: stops serving that family.
  /// Its data stays in `logs/<id>/`, so adding its address again brings it back; with
  /// `delete_data`, it is deleted, and the record with it. Deleting a family the host still has
  /// takes its id, never its address, so a mistyped name can't delete a family in use.
  Future<Response> _removeFamily(String which, {bool delete = false}) async {
    final log = state.find(which);
    if (log == null) throw ApiError.notFound(type: 'family', message: 'No family other than the first is at $which.');
    if (!delete && log.removed) throw ApiError.notFound(type: 'family', message: 'No family other than the first is at $which.');
    if (delete && !log.removed && which != log.id) {
      throw ApiError(409, 'in_use', '${log.hostname ?? log.id} is still on this host. Take it off first, or name it by its id (${log.id}) to take it off and delete its data.');
    }
    if (delete && config.deleteLog == null) throw ApiError(501, 'unavailable', 'This host can\'t delete a family\'s data while it runs. Stop it first.');
    final tenant = _ids.entries.where((e) => e.value == log.id).firstOrNull?.key;
    if (tenant != null) await remove(tenant);
    if (!log.removed) state.put(log.copyWith(removed: true));
    _whyNot.remove(log.id);
    if (!delete) {
      this.log.info('Stopped serving ${log.hostname ?? log.id}; its data stays in $hostLogsDir/${log.id}');
      return jsonResponse({'ok': true, 'id': log.id});
    }
    try {
      await config.deleteLog!(log);
    } on StateError catch (e) {
      throw ApiError(409, 'busy', '${log.hostname ?? log.id} is off the host, but its data wasn\'t deleted: ${e.message}');
    }
    state.forget(log.id);
    this.log.info('Deleted the data of ${log.hostname ?? log.id}');
    return jsonResponse({'ok': true, 'id': log.id, 'deleted': true});
  }

  /// The families `host.json` lists that aren't attached.
  List<HostedLog> get _missing => [for (final l in state.logs) if (!_ids.containsValue(l.id)) l];

  /// Opens and serves every family `host.json` lists that isn't served yet ([HostConfig.openLog]).
  /// One that doesn't open (its data directory's lock held by a backup, say) is logged and tried
  /// again every [HostConfig.retryInterval]; until it opens, requests to its address are answered
  /// `503`. The host's `/health` fails until this first pass is done, then answers `200` (the
  /// families that did open are served), with how many aren't. Returns the families still
  /// missing.
  Future<List<HostedLog>> openConfigured() async {
    final missing = await _serial(_openMissing);
    _settled = true;
    _retry ??= Timer.periodic(config.retryInterval, (_) {
      if (_stopped || _missing.isEmpty) return;
      unawaited(_serial(_openMissing).then((_) {}, onError: (Object _) {}));
    });
    return missing;
  }

  Future<List<HostedLog>> _openMissing() async {
    for (final l in _missing) {
      try {
        await _open(l, fresh: false);
        _whyNot.remove(l.id);
        log.info('Serving ${l.hostname ?? l.id}');
      } on Object catch (e) {
        final why = e is ApiError ? e.message : (e is StateError ? e.message : (e is FileSystemException ? e.message : '${e.runtimeType}'));
        _whyNot[l.id] = why;
        log.error('Not serving ${l.hostname ?? l.id} yet ($why); trying again in ${config.retryInterval.inSeconds}s');
      }
    }
    return _missing;
  }

  /// Called by a tenant once it has stopped: closes what the host opened for it.
  Future<void> closed(DenHub tenant) async {
    final opened = _opened.remove(tenant);
    if (opened != null) await opened.close();
  }

  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// The family other than the hub [from]'s whose calendar link [request] reads (`GET` or `HEAD`
  /// of `/ics/<secret>/<file>` at its `https` address, on the port its address names), or null.
  /// Nothing else is answered in-process: every other request goes out through NetGuard as any
  /// fetch does.
  DenHub? _otherFamilyAt(http_client.BaseRequest request, String from) {
    final url = request.url;
    if (_stopped || !url.isScheme('https') || url.userInfo.isNotEmpty) return null;
    if (request.method != 'GET' && request.method != 'HEAD') return null;
    final path = url.pathSegments;
    if (path.length != 3 || path[0] != 'ics' || path[1].isEmpty || path[2].isEmpty) return null;
    final at = router.mapped(normalizeHostname(url.host));
    if (at == null || at.hubDevice == from || at.config.publicUrl?.port != url.port) return null;
    return at;
  }

  /// Stops every family, then the server.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _retry?.cancel();
    for (final t in List.of(_tenants).reversed) {
      await t.stop();
    }
    await _server?.close(force: true);
    if (_ownsHttp) http.close();
    fetch.close();
  }
}

/// One family's outgoing client for the calendar feeds it subscribes to ([DenHost.fetchFor],
/// [HubContext.feedFetch]): reading another family's calendar link on the same host (`GET /ics/<secret>/shared.ics`, and its
/// watch stream) is answered by the host in this process, as if it had come in from outside
/// with nothing but its secret, so it needs no DNS, no `extra_hosts` and no `DEN_PEER_HUBS`, and
/// never leaves the machine. It counts against the limits of the hub that asked
/// ([inProcessClient]), so one family's bad links never use up another's. Everything else (any
/// other path or method, its own family's address) goes through the host's [NetGuard] client as
/// before.
class _OtherFamilies extends http_client.BaseClient {
  _OtherFamilies(this._host, this._from);

  final DenHost _host;
  final String _from;

  @override
  Future<http_client.StreamedResponse> send(http_client.BaseRequest request) async {
    final url = request.url;
    if (_host._otherFamilyAt(request, _from) == null) return _host.fetch.send(request);
    final response = await _host._handler(Request(
      request.method,
      url,
      headers: {...request.headers, 'host': url.host},
      body: request.finalize(),
      context: {inProcessClient: _from},
    ));
    return http_client.StreamedResponse(
      response.read(),
      response.statusCode,
      contentLength: response.contentLength,
      request: request,
      headers: {for (final e in response.headers.entries) e.key.toLowerCase(): e.value},
    );
  }

  /// The host's client stays open for the other families; the host closes it.
  @override
  void close() {}
}
