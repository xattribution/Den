import 'dart:async';

import 'package:den_actions/den_actions.dart' show standardRunner;
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:shelf/shelf.dart';
import 'package:stream_channel/stream_channel.dart';

import 'access.dart';
import 'accounts.dart';
import 'api.dart';
import 'assistant.dart';
import 'capture.dart';
import 'config.dart';
import 'context.dart';
import 'device_auth.dart';
import 'edge.dart';
import 'feed.dart';
import 'gate.dart';
import 'host.dart';
import 'host_state.dart';
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
import 'passkeys/passkeys.dart';
import 'push/push_service.dart';
import 'recovery.dart';
import 'relay_watch.dart';
import 'reminders.dart';
import 'screen_codes.dart';
import 'server/first_boot.dart';
import 'server/server_api.dart';
import 'setup.dart';
import 'sign_in_setup.dart';
import 'state.dart';
import 'tenant_router.dart';
import 'usage.dart';

/// The Den hub: the family's always-on device. Serves device sync at `/ws`, the HTTP API and
/// event stream under `/api/v1`, MCP at `/mcp` with OAuth for remote clients, calendar feeds,
/// reminders, mDNS, and the web app, all on one port.
///
/// Runs anywhere `dart:io` does: the `den_hub` binary, or in-process inside the Den app on
/// desktop and Android (where [den] is the app's own engine, in hub mode).
///
/// A hub is one family (a tenant) of a [DenHost], which owns the server and hands it the
/// requests ([handle]) and sync connections ([serveSocket]) that are its family's.
/// [DenHub.start] runs a host with this one family, as a hub always ran.
class DenHub implements RoutableLog {
  DenHub._(this.den, this._ctx, this._feed, this._host);

  /// The hub's engine. A fresh one with no family waits for setup.
  final Den den;

  /// How the hub runs.
  HubConfig get config => _ctx.config;

  /// Gives the hub the family's [address], learned at first boot (first_boot.dart): links, OAuth
  /// and the public posture follow it from the next request on.
  void setPublicUrl(Uri address) {
    _ctx.config = _ctx.config.withPublicUrl(address);
    if (identical(_host.ownFamily, this)) _host.state.notePrimary(address);
  }

  final HubContext _ctx;
  final ChangeFeed _feed;
  final DenHost _host;
  bool _ownsHost = false;
  late final HubSetup _setup;
  late final LinkSlots _links;
  late final HubInvites _invites;
  late final ScreenCodes _screens;
  late final HubFeedLinks _feedLinks;
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
  late final HubAccounts _accounts;
  late final HubPasskeys _passkeys;
  final Routes _routes = Routes();
  late final DeviceAuth _auth;
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

  /// Starts a hub over [den] (already open) and begins serving: a [DenHost] of its own with this
  /// one family, which answers whatever address it is asked at. [stop] stops both.
  static Future<DenHub> start(Den den, HubConfig config) async {
    final host = await DenHost.start(HostConfig.of(config));
    try {
      final hub = await host.add(den, config);
      hub._ownsHost = true;
      return hub;
    } catch (_) {
      await host.stop();
      rethrow;
    }
  }

  /// Starts [den]'s hub as one family of [host] ([DenHost.add] calls this): its own engine,
  /// state and services, with the host's server, limits and clients.
  static Future<DenHub> tenantOf(DenHost host, Den den, HubConfig config) async {
    final node = SyncNode(den, invites: HubInviteBook());
    final ctx = HubContext(
      den: den,
      gate: DenGate(den),
      config: config,
      log: config.log ?? host.log,
      state: HubState(config.dataDir),
      node: node,
      http: host.http,
      fetch: host.fetch,
      feedFetch: host.fetchFor(den.deviceId),
      host: host,
    );
    final hub = DenHub._(den, ctx, ChangeFeed(den), host);
    await hub._start();
    return hub;
  }

  /// The shared context, for the hub's own services.
  HubContext get context => _ctx;

  /// The host this hub is one family of.
  DenHost get host => _host;

  /// Sync for [den]; devices connect to it at `/ws`.
  SyncNode get node => _ctx.node;

  /// The port being served.
  int get port => _host.port;

  /// `http://127.0.0.1:<port>`.
  Uri get localUrl => _host.localUrl;

  @override
  String? get familyId => den.familyId;

  @override
  String get hubDevice => den.deviceId;

  @override
  Set<String> get hostnames => {?normalizeHostname(config.publicUrl?.host)};

  /// Invites by message, for the host's lookups across families.
  HubInvites get invites => _invites;

  /// Kitchen screens waiting for a parent to type their code.
  ScreenCodes get screens => _screens;

  /// Whether [request]'s signature checks out for this hub from its headers alone: signed for
  /// this hub, with the body hash it covers, by an approved device of this family, fresh. No side
  /// effects; the host hands the request here only then ([DenHost], `X-Den-Hub`).
  Future<bool> verifiesHeaders(Request request) => _auth.headersVerify(request);

  /// Whether [token] is a working token of this family's.
  bool holdsToken(String token) => _ctx.ready && _ctx.access(token) != null;

  /// Whether this family made the calendar link with [secret].
  bool holdsFeed(String secret) => _ctx.ready && _feedLinks.holds(secret);

  /// Whether a browser waits here under the link code [slot].
  bool holdsLinkSlot(String slot) => _links.holds(slot);

  /// Whether this hub waits for its first parent's phone with the setup code [code].
  bool waitsForSetupCode(String code) => !_ctx.ready && _setup.codeMatches(code);

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

  /// Signing in with Google and Apple, when configured.
  HubAccounts get accounts => _accounts;

  /// Passkeys: how a family member gets back in on a browser.
  HubPasskeys get passkeys => _passkeys;

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
    final feedLinks = _feedLinks = HubFeedLinks(_ctx, _auth);
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
    _routes
      ..add('GET', '/health', (r, _) => _health())
      ..add('GET', '/api/v1/hub/status', (r, _) => _setup.status(r))
      ..add('POST', '/api/v1/hub/setup', (r, _) => _setup.setup(r))
      ..add('GET', '/api/v1/hub/setup/ws', (r, _) {
        _host.admitSocket(r);
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
    _invites = HubInvites(_ctx)..register(_routes);
    _screens = ScreenCodes(_ctx, _auth)..register(_routes);
    feedLinks.register(_routes);
    _recovery = HubRecovery(_ctx, _auth)..register(_routes);
    _passkeys = HubPasskeys(_ctx, _auth, _recovery)..register(_routes);
    _push.register(_routes);
    _accounts = HubAccounts(_ctx, _auth)..register(_routes);
    HubSignInSetup(_ctx, _auth).register(_routes);
    final firstBoot = FirstBoot(_ctx, _setup, _host,
        setAddress: setPublicUrl, isOwn: () => identical(_host.ownFamily, this) && _host.idOf(this) == null)
      ..register(_routes);
    _setup.firstBoot = firstBoot.statusPart;
    ServerApi(_ctx, _auth, _host).register(_routes);
    _changes = den.onChange.listen((_) {
      _setup.refresh();
      final m = _mdns;
      if (m != null && !_sameAdvert(m.advert, _advert())) unawaited(m.update(_advert()));
    });
    log.info('Den hub ${den.deviceId} serving on port ${_host.port}');
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
        port: _host.port,
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

  /// Answers [request], which the host found to be this family's: first what every request
  /// passes (the anonymous budget, the body size), then its route; `404` for none.
  Future<Response> handle(Request request) async {
    final admitted = await _admit(request);
    final found = _routes.find(admitted);
    if (found != null) return found.$1.handler(admitted, found.$2);
    throw ApiError.notFound();
  }

  /// Serves one sync connection the host found to be this family's (its hello names this
  /// family, or none at this family's address), until it closes. [client] says where it came
  /// from. The sync node checks the hello in full and refuses any other family.
  Future<void> serveSocket(StreamChannel<dynamic> channel, {String? client}) async {
    if (_stopped) {
      unawaited(channel.sink.close().then((_) {}, onError: (Object _) {}));
      return;
    }
    await node.serve(channel, client: client);
  }

  /// What every request passes before it is routed: a per-client budget for requests without
  /// a working token or device signature (this machine itself excepted), and a body no larger
  /// than the endpoint takes, refused by its declared length before a byte is read. The budget
  /// is the host's, shared by every family on it.
  ///
  /// A request counts as signed only once what it carries checks out: a bearer token this
  /// family knows, or a device signature over the body hash it claims. Any other header (a
  /// made-up token, a signature that doesn't verify, or one that can't be checked before the
  /// body) is a request like any stranger's.
  Future<Request> _admit(Request request) async {
    var admitted = request;
    // Counted already, or (the host checked its signature for this hub) signed.
    final settled = request.context[DenHost.admittedKey] == true || request.context[DeviceAuth.verifiedHeaders] == true;
    if (!settled) {
      final forwarded = request.headers.containsKey('x-forwarded-for');
      if (forwarded && !viaTrustedProxy(request, config.trustedProxies)) _host.warnUntrustedProxy(request);
      if (!DenHost.local(request)) {
        if (await _auth.headersVerify(request)) {
          admitted = request.change(context: {DeviceAuth.verifiedHeaders: true});
        } else if (!_tokenWorks(request)) {
          _ctx.limit(request, 'anonymous', Limits.anonymous);
        }
      }
    }
    final declared = request.contentLength;
    if (declared != null && declared > _bodyLimit(request)) throw ApiError.tooLarge();
    return admitted;
  }

  /// Whether [request] carries a bearer token that resolves to a working connection.
  bool _tokenWorks(Request request) {
    final token = bearerToken(request.headers['authorization']);
    return token != null && _ctx.ready && _ctx.access(token) != null;
  }

  int _bodyLimit(Request request) => switch (request.url.path) {
        'api/v1/capture/read' => HubCapture.maxBody,
        'api/v1/assistant/model' => HubAssistant.maxBody,
        'api/v1/hub/first-boot/upload' => maxBackupUpload,
        _ => maxBodyBytes,
      };

  Response _openStream(Request request) {
    final access = _api.authenticate(request, Scope.read);
    return _stream.open(access, bearerToken(request.headers['authorization'])!);
  }

  /// Stops serving: says goodbye to event streams and mDNS, closes sync and the tunnel. The host
  /// sends this family nothing more; a hub that [start] made stops its host too.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _host.detach(this);
    await _stream.shutdown();
    await _mcpHttp.shutdown();
    await _ics.shutdown();
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
    await _ctx.state.flush();
    _ctx.log.info('Den hub stopped');
    await _host.closed(this);
    if (_ownsHost) await _host.stop();
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
