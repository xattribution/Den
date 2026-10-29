import 'dart:async';
import 'dart:io';

import 'package:den_actions/den_actions.dart' show standardRunner;
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:den_net/io.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'access.dart';
import 'api.dart';
import 'assistant.dart';
import 'capture.dart';
import 'config.dart';
import 'context.dart';
import 'device_auth.dart';
import 'edge.dart';
import 'feed.dart';
import 'gate.dart';
import 'http_util.dart';
import 'ics/export.dart';
import 'ics/feeds.dart';
import 'feed_links.dart';
import 'invites.dart';
import 'log.dart';
import 'mcp/http.dart';
import 'mdns/responder.dart';
import 'mcp/server.dart';
import 'oauth.dart';
import 'push/push_service.dart';
import 'recovery.dart';
import 'relay_watch.dart';
import 'reminders.dart';
import 'setup.dart';
import 'state.dart';
import 'usage.dart';
import 'web.dart';

/// The Den hub: the family's always-on device. Serves device sync at `/ws`, the HTTP API and
/// event stream under `/api/v1`, MCP at `/mcp` with OAuth for remote clients, calendar feeds,
/// reminders, mDNS, and the web app, all on one port.
///
/// Runs anywhere `dart:io` does: the `den_hub` binary, or in-process inside the Den app on
/// desktop and Android (where [den] is the app's own engine, in hub mode).
class DenHub {
  DenHub._(this.den, this.config, this._ctx, this._feed, this._ownsHttp);

  /// The hub's engine. A fresh one with no family waits for setup.
  final Den den;

  /// How the hub runs.
  final HubConfig config;

  final HubContext _ctx;
  final ChangeFeed _feed;
  final bool _ownsHttp;
  late final HubSetup _setup;
  late final LinkSlots _links;
  late final EventStream _stream;
  late final RestApi _api;
  late final HubCapture _capture;
  late final HubAssistant _assistant;
  late final McpServer _mcp;
  late final McpHttp _mcpHttp;
  late final OAuthServer _oauth;
  late final IcsExport _ics;
  late final FeedService _feeds;
  late final ReminderService _reminders;
  late final WebPushService _push;
  late final HubRecovery _recovery;
  final Routes _routes = Routes();
  late final DeviceAuth _auth;
  final Map<String, int> _sockets = {};
  final Set<String> _warnedProxies = {};
  Handler? _web;
  HttpServer? _server;
  RelayTunnel? _tunnel;
  MailboxSync? _mailbox;
  late final RelayWatch _relayWatch = RelayWatch(_ctx.log);
  MdnsResponder? _mdns;
  StreamSubscription<Set<String>>? _changes;
  StreamSubscription<SyncPeer>? _peers;
  final List<HubService> _services = [];

  /// Services that write to the family's log on their own (calendar feeds, the OAuth sweep):
  /// held while the hub [catchingUp] after a restore, started once it has caught up.
  final Set<HubService> _writers = {};
  final List<HubService> _held = [];
  bool _servicesStarted = false;
  bool _stopped = false;

  /// Starts a hub over [den] (already open) and begins serving.
  static Future<DenHub> start(Den den, HubConfig config) async {
    final log = config.log ?? HubLog();
    final client = config.httpClient ?? http.Client();
    final node = SyncNode(den);
    final ctx = HubContext(
      den: den,
      gate: DenGate(den),
      config: config,
      log: log,
      state: HubState(config.dataDir),
      node: node,
      http: client,
      fetch: config.fetchClient,
    );
    final hub = DenHub._(den, config, ctx, ChangeFeed(den), config.httpClient == null);
    await hub._start();
    return hub;
  }

  /// The shared context, for the hub's own services.
  HubContext get context => _ctx;

  /// Sync for [den]; devices connect to it at `/ws`.
  SyncNode get node => _ctx.node;

  /// The port being served.
  int get port => _server!.port;

  /// `http://127.0.0.1:<port>`.
  Uri get localUrl => Uri.parse('http://127.0.0.1:$port');

  /// The setup code while the hub has no family (shown as `ABCD-EFGH`), else null.
  String? get setupCode => _setup.code == null ? null : HubSetup.display(_setup.code!);

  /// The MCP server, for other transports (stdio).
  McpServer get mcp => _mcp;

  /// Reading what devices share, with the reader a parent set up on the hub.
  HubCapture get capture => _capture;

  /// The in-app assistant's model requests, sent on with the key a parent gave the hub.
  HubAssistant get assistant => _assistant;

  /// OAuth for remote MCP clients; [OAuthServer.sweep] expires sign-in requests now.
  OAuthServer get oauth => _oauth;

  /// Calendar feeds in; [FeedService.syncAll] refreshes them now.
  FeedService get feeds => _feeds;

  /// Reminders out; [ReminderService.tick] looks ahead now.
  ReminderService get reminders => _reminders;

  /// Reminders and nudges to browsers through Web Push.
  WebPushService get push => _push;

  /// Server-assisted recovery, for a family that turned it on.
  HubRecovery get recovery => _recovery;

  /// Where setup stands.
  SetupStage get setupStage => _setup.stage;

  /// Whether the hub is in a family, approved, and serving the API.
  bool get ready => _ctx.ready;

  /// Whether the hub was restored from a backup and waits for a device of the family to sync
  /// before it writes anything of its own ([HubContext.catchingUp]).
  bool get catchingUp => _ctx.catchingUp;

  /// Adds a service started once the hub is ready and stopped with it.
  void addService(HubService service) {
    _services.add(service);
    if (_servicesStarted) unawaited(_startService(service));
  }

  Future<void> _start() async {
    final log = _ctx.log;
    _auth = DeviceAuth(_ctx);
    _setup = HubSetup(_ctx, onReady: _onReady);
    _links = LinkSlots(_ctx, _auth);
    _stream = EventStream(_ctx, _feed);
    final usage = AiUsage(_ctx);
    _capture = HubCapture(_ctx, _auth, usage);
    // One runner for REST and MCP: a connection's receipts and confirmations work on either.
    final actions = standardRunner();
    _api = RestApi(_ctx, runner: actions, reader: _capture.reader);
    _mcp = McpServer(_ctx, runner: actions, reader: _capture.reader);
    _mcpHttp = McpHttp(_ctx, _mcp, _feed);
    _oauth = OAuthServer(_ctx, _auth);
    final feedLinks = HubFeedLinks(_ctx, _auth);
    _ics = IcsExport(_ctx, links: feedLinks);
    _feeds = FeedService(_ctx);
    _reminders = ReminderService(_ctx);
    _push = WebPushService(_ctx, _auth);
    _reminders.sinks.add(_push);
    _services
      ..add(_feeds)
      ..add(_reminders)
      ..add(_oauth)
      ..add(_push);
    _writers.addAll([_feeds, _oauth]);
    if (_ctx.catchingUp) {
      log.warn('Restored from a backup: this hub writes nothing of its own until a phone or tablet in the family '
          'has synced with it. Open Den on one.');
      _peers = node.peerConnected.listen(_watchCatchUp);
    }
    _web = webAppHandler(config.webDir, policy: _webPolicy);
    _routes
      ..add('GET', '/health', (r, _) => _health())
      ..add('GET', '/api/v1/hub/status', (r, _) => _setup.status(r))
      ..add('POST', '/api/v1/hub/setup', (r, _) => _setup.setup(r))
      ..add('GET', '/api/v1/hub/setup/ws', (r, _) {
        _admitSocket(r);
        return _setup.backChannel(r);
      })
      ..add('POST', '/api/v1/link', (r, _) => _links.create(r))
      ..add('POST', '/api/v1/link/window', (r, _) => _links.openWindow(r))
      ..add('POST', '/api/v1/link/<slot>', (r, p) => _links.grant(r, p['slot']!))
      ..add('GET', '/api/v1/link/<slot>', (r, p) => _links.poll(r, p['slot']!))
      ..add('GET', '/api/v1/stream', (r, _) => _openStream(r))
      ..add('POST', '/mcp', (r, _) => _mcpHttp.post(r))
      ..add('GET', '/mcp', (r, _) => _mcpHttp.get(r))
      ..add('DELETE', '/mcp', (r, _) => _mcpHttp.delete(r))
      ..add('OPTIONS', '/mcp', (r, _) => _mcpHttp.options(r))
      ..add('GET', '/.well-known/oauth-protected-resource', (r, _) => _oauth.resourceMetadata(r))
      ..add('GET', '/.well-known/oauth-protected-resource/mcp', (r, _) => _oauth.resourceMetadata(r))
      ..add('GET', '/.well-known/oauth-authorization-server', (r, _) => _oauth.serverMetadata(r))
      ..add('POST', '/oauth/register', (r, _) => _oauth.register(r))
      ..add('OPTIONS', '/oauth/register', (r, _) => _mcpHttp.options(r))
      ..add('GET', '/oauth/authorize', (r, _) => _oauth.authorize(r))
      ..add('GET', '/oauth/authorize/status', (r, _) => _oauth.status(r))
      ..add('POST', '/oauth/token', (r, _) => _oauth.token(r))
      ..add('OPTIONS', '/oauth/token', (r, _) => _mcpHttp.options(r))
      ..add('GET', '/api/v1/connections/requests', (r, _) => _oauth.requests(r))
      ..add('POST', '/api/v1/connections/requests/<id>', (r, p) => _oauth.decide(r, p['id']!))
      ..add('GET', '/api/v1/connections/clients', (r, _) => _oauth.clients(r))
      ..add('POST', '/api/v1/connections/clients', (r, _) => _oauth.createClient(r))
      ..add('DELETE', '/api/v1/connections/clients/<id>', (r, p) => _oauth.deleteClient(r, p['id']!))
      ..add('GET', '/ics/<token>/<file>', (r, p) => _ics.feed(r, p['token']!, p['file']!));
    _api.register(_routes);
    _capture.register(_routes);
    _assistant = HubAssistant(_ctx, _auth, usage)..register(_routes);
    HubInvites(_ctx).register(_routes);
    feedLinks.register(_routes);
    _recovery = HubRecovery(_ctx, _auth)..register(_routes);
    _push.register(_routes);
    _changes = den.onChange.listen((_) {
      _setup.refresh();
      final m = _mdns;
      if (m != null && !_sameAdvert(m.advert, _advert())) unawaited(m.update(_advert()));
    });
    final pipeline = const Pipeline().addMiddleware(_headers).addMiddleware(_errors).addMiddleware(_admission).addHandler(_route);
    _server = await shelf_io.serve(pipeline, config.bindAddress, config.port);
    _server!.idleTimeout = const Duration(seconds: 120);
    log.info('Den hub ${den.deviceId} serving on port ${_server!.port}');
    if (config.mdns) {
      final mdns = _mdns = MdnsResponder(_advert(), log: log);
      await _guarded('mDNS', mdns.start);
    }
    final relay = config.relay;
    if (relay != null) {
      final tunnel = _tunnel = RelayTunnel(relay: relay, keys: den.keys, onClient: (c) => unawaited(node.serve(c)));
      _relayWatch.watchTunnel(tunnel);
      tunnel.start();
      log.info('Keeping a tunnel open through the relay');
    }
    if (_ctx.ready) _onReady();
  }

  void _onReady() {
    if (_servicesStarted || _stopped) return;
    _servicesStarted = true;
    final relay = config.relay;
    if (relay != null && config.mailbox) {
      final mailbox = _mailbox = MailboxSync(node: node, relay: RelayMailbox(relay));
      _relayWatch.runMailbox(mailbox);
    }
    for (final s in _services) {
      if (_ctx.catchingUp && _writers.contains(s)) {
        _held.add(s);
      } else {
        unawaited(_startService(s));
      }
    }
  }

  Future<void> _startService(HubService s) => _guarded(s.name, s.start);

  /// While catching up after a restore: once [peer] (an approved device of the family, not this
  /// hub) has finished its first exchange, the hub holds what that device had of the hub's own
  /// later changes, and den_core numbers new ones past them. Then the hub writes again.
  void _watchCatchUp(SyncPeer peer) {
    unawaited(peer.live.then((_) async {
      if (_stopped || !_ctx.catchingUp) return;
      final d = den.device(peer.deviceId);
      if (d == null || d.id == den.deviceId || !d.approved || d.revoked) return;
      await _ctx.state.delete(restoreMarkerDoc);
      _ctx.log.info('Caught up after the restore: ${d.name} synced with the hub, which writes again');
      await _peers?.cancel();
      _peers = null;
      final held = [..._held];
      _held.clear();
      if (_servicesStarted && !_stopped) {
        for (final s in held) {
          unawaited(_startService(s));
        }
      }
    }, onError: (Object _) {}));
  }

  /// Runs [body] in a zone whose uncaught errors are logged instead of reaching the process (or
  /// the app running the hub). The parts of the hub that act on their own, on timers or on
  /// packets from the network (mDNS, feeds, reminders), start here, so no packet, feed or
  /// notifier can take the hub down.
  Future<void> _guarded(String what, Future<void> Function() body) {
    final started = Completer<void>();
    void finish() {
      if (!started.isCompleted) started.complete();
    }

    runZonedGuarded(() {
      unawaited(body().then((_) => finish(), onError: (Object e, StackTrace st) {
        _ctx.log.error('$what didn\'t start: ${describeError(e, st)}');
        finish();
      }));
    }, (e, st) {
      _ctx.log.error('$what failed: ${describeError(e, st)}');
      finish();
    });
    return started.future;
  }

  /// What mDNS advertises: TXT `id`, `name`, `version`, `api` and, in a family, `f`.
  MdnsAdvert _advert() => MdnsAdvert(
        instance: _ctx.name,
        host: 'den-${den.deviceId.substring(0, 8)}',
        port: _server?.port ?? config.port,
        txt: {
          'id': den.deviceId,
          'name': _ctx.name,
          'version': hubVersion,
          'api': '1',
          if (den.familyId != null) 'f': den.familyId!,
        },
      );

  static bool _sameAdvert(MdnsAdvert a, MdnsAdvert b) =>
      a.instance == b.instance && a.port == b.port && a.txt.length == b.txt.length && a.txt.entries.every((e) => b.txt[e.key] == e.value);

  /// `GET /health`. In the public posture it says only that the hub serves and whether it is
  /// ready: nothing that tells a stranger which hub, which family or which version.
  Response _health() => jsonResponse({
        'ok': true,
        'api': 1,
        'ready': _ctx.ready,
        if (!config.publicPosture) ...{'version': hubVersion, 'device': den.deviceId, 'name': _ctx.name},
      });

  /// The web app's Content-Security-Policy for [request]: `DEN_CSP` when set, else
  /// [webAppPolicy] allowing sync over the hub's own `ws:`/`wss:` origin.
  String _webPolicy(Request request, List<String> scriptHashes) {
    final custom = config.contentSecurityPolicy;
    if (custom != null && custom.trim().isNotEmpty) return custom;
    final base = _ctx.base(request);
    return webAppPolicy(connect: '${base.scheme == 'https' ? 'wss' : 'ws'}://${base.authority}', scriptHashes: scriptHashes);
  }

  /// Admits a WebSocket upgrade from [request]'s client, within its budget of new connections
  /// a minute and connections open at once, and returns the client's key.
  String _admitSocket(Request request) {
    _ctx.limit(request, 'sockets', Limits.sockets, message: 'Too many connections from here. Wait a minute.');
    final key = _ctx.clientOf(request);
    if ((_sockets[key] ?? 0) >= Limits.openSockets) {
      throw ApiError.rateLimited(30, 'Too many connections from here. Close some and try again.');
    }
    return key;
  }

  /// `GET /ws`: device sync over a WebSocket whose messages den_net bounds as they arrive (a
  /// frame announcing more than a session carries closes it before anything is buffered),
  /// counted against its client's connections while it is open.
  FutureOr<Response> _ws(Request request) {
    final key = _admitSocket(request);
    return boundedWebSocketHandler(
      (socket) {
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
        // Devices that aren't approved yet get places per client, so no one address can keep
        // everyone else from joining or recovering.
        unawaited(node.serve(socket, client: key));
      },
      maxMessageBytes: maxSyncSocketMessageBytes,
      pingInterval: const Duration(seconds: 30),
    )(request);
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
          if (_ctx.secure(request)) 'strict-transport-security': 'max-age=31536000',
          if (html) 'x-frame-options': 'DENY',
          if (html) 'cross-origin-opener-policy': 'same-origin',
          if (type.startsWith('application/json') && !response.headers.containsKey('content-security-policy'))
            'content-security-policy': "default-src 'none'; frame-ancestors 'none'",
        });
      };

  /// What every request passes before it is routed: a per-client budget for requests without
  /// a working token or device signature (this machine itself excepted), and a body no larger
  /// than the endpoint takes, refused by its declared length before a byte is read.
  ///
  /// A request counts as signed only once what it carries checks out: a bearer token the hub
  /// knows, or a device signature over the body hash it claims. Any other header (a made-up
  /// token, a signature that doesn't verify, or one that can't be checked before the body) is a
  /// request like any stranger's.
  Handler _admission(Handler inner) => (Request request) async {
        final forwarded = request.headers.containsKey('x-forwarded-for');
        if (forwarded && !viaTrustedProxy(request, config.trustedProxies)) _warnUntrustedProxy(request);
        final peer = peerAddress(request);
        final local = peer != null && peer.isLoopback && !forwarded;
        var admitted = request;
        if (!local) {
          if (await _auth.headersVerify(request)) {
            admitted = request.change(context: {DeviceAuth.verifiedHeaders: true});
          } else if (!_tokenWorks(request)) {
            _ctx.limit(request, 'anonymous', Limits.anonymous);
          }
        }
        final declared = request.contentLength;
        if (declared != null && declared > _bodyLimit(request)) throw ApiError.tooLarge();
        return inner(admitted);
      };

  /// Whether [request] carries a bearer token that resolves to a working connection.
  bool _tokenWorks(Request request) {
    final token = bearerToken(request.headers['authorization']);
    return token != null && _ctx.ready && accessForToken(den, token) != null;
  }

  int _bodyLimit(Request request) => switch (request.url.path) {
        'api/v1/capture/read' => HubCapture.maxBody,
        'api/v1/assistant/model' => HubAssistant.maxBody,
        _ => maxBodyBytes,
      };

  void _warnUntrustedProxy(Request request) {
    final peer = peerAddress(request)?.address;
    if (peer == null || _warnedProxies.length >= 16 || !_warnedProxies.add(peer)) return;
    _ctx.log.warn('Requests from $peer carry X-Forwarded-For, but DEN_TRUSTED_PROXIES doesn\'t list $peer, so the hub '
        'ignores the header and limits everyone behind that proxy as one client. List the proxy to fix that.');
  }

  Response _openStream(Request request) {
    final access = _api.authenticate(request, Scope.read);
    return _stream.open(access, bearerToken(request.headers['authorization'])!);
  }

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
          _ctx.log.error('${request.method} ${_safePath(request)} failed: ${describeError(e, st)}');
          response = ApiError(500, 'internal', 'Something went wrong on the hub.').toResponse();
        }
        _ctx.log.debug(
            '${request.method} ${_safePath(request)} ${response.statusCode} ${DateTime.now().difference(started).inMilliseconds}ms');
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

  FutureOr<Response> _route(Request request) {
    final path = request.url.path;
    if (path == 'ws') return _ws(request);
    final found = _routes.find(request);
    if (found != null) return found.$1.handler(request, found.$2);
    final web = _web;
    final first = request.url.pathSegments.isEmpty ? '' : request.url.pathSegments.first;
    const reserved = {'api', 'mcp', 'oauth', 'ics', '.well-known', 'ws', 'health'};
    if (web != null && !reserved.contains(first)) return web(request);
    throw ApiError.notFound();
  }

  /// Stops serving: says goodbye to event streams and mDNS, closes sync and the tunnel.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _stream.shutdown();
    await _mcpHttp.shutdown();
    for (final s in _services.reversed) {
      try {
        await s.stop();
      } on Object catch (e, st) {
        _ctx.log.warn('${s.name} didn\'t stop cleanly: ${describeError(e, st)}');
      }
    }
    await _changes?.cancel();
    await _peers?.cancel();
    await _mdns?.stop();
    await _relayWatch.stop();
    await _mailbox?.stop();
    await _tunnel?.stop();
    await node.close();
    await _feed.close();
    await _server?.close(force: true);
    await _ctx.state.flush();
    if (_ownsHttp) _ctx.http.close();
    _ctx.fetch.close();
    _ctx.log.info('Den hub stopped');
  }
}

/// A background part of the hub (calendar feeds, reminders, mDNS), started once the hub is in a
/// family and stopped with it.
abstract class HubService {
  /// A name for the log.
  String get name;

  /// Starts the service.
  Future<void> start();

  /// Stops the service.
  Future<void> stop();
}
