import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http_client;
import 'package:shelf/shelf.dart';

import 'access.dart';
import 'config.dart';
import 'edge.dart';
import 'gate.dart';
import 'host_state.dart';
import 'http_util.dart';
import 'log.dart';
import 'net_guard.dart';
import 'oauth_store.dart';
import 'state.dart';

/// What every part of the hub shares.
class HubContext {
  /// Creates the shared context. In a Den host, [host] gives the host-wide limits, and the host's
  /// clients are [http], [fetch] and [feedFetch].
  HubContext({
    required this.den,
    required this.gate,
    required this.config,
    required this.log,
    required this.state,
    required this.node,
    required this.http,
    http_client.Client? fetch,
    http_client.Client? feedFetch,
    this.host,
  })  : fetch = fetch ??
            NetGuard(resolve: config.resolver, allow: config.fetchAllow, hubs: [?config.publicUrl, ...config.peerHubs]).client(),
        _feedFetch = feedFetch,
        limits = host?.limits ?? RateLimiter();

  /// The Den host this hub is one family of, or null for a context made on its own (the command
  /// line's offline tools).
  final HostLink? host;

  /// The hub's engine.
  final Den den;

  /// Serializes acting on [den].
  final DenGate gate;

  /// How the hub runs. Changes only when the server learns the family's address at first boot
  /// ([HubConfig.withPublicUrl]).
  HubConfig config;

  /// Where the hub logs.
  final HubLog log;

  /// The hub's own small state.
  final HubState state;

  /// Sync for [den].
  final SyncNode node;

  /// Outgoing HTTP to what the operator configured (notifiers, readers, model providers).
  final http_client.Client http;

  /// Outgoing HTTP to addresses callers gave the hub (OAuth client metadata, and anything else
  /// but calendar feeds): [NetGuard]'s client, which refuses the hub's own machine and network
  /// (except the configured hubs' names, [HubConfig.peerHubs], which may lead to loopback).
  final http_client.Client fetch;

  final http_client.Client? _feedFetch;

  /// Outgoing HTTP for the calendar feeds the family subscribes to: [fetch], except that on a Den
  /// host another family's calendar link there is read in the host's own process
  /// (`DenHost.fetchFor`). Only the feed service uses it, so nothing an anonymous caller names
  /// (an OAuth client's metadata address, say) is ever read in-process.
  http_client.Client get feedFetch => _feedFetch ?? fetch;

  /// In a family, approved, log loaded: the API answers.
  bool get ready => den.hasFamily && den.isApproved;

  /// OAuth clients and the hashes of the access and refresh tokens the hub issued.
  late final OAuthStore oauthStore = OAuthStore(state);

  /// The caller a bearer [token] belongs to: a token a parent made, or an OAuth access token the
  /// hub issued, for a connection that is still on. Null otherwise.
  Access? access(String? token) => accessForToken(den, token, oauth: oauthStore, now: now());

  /// Restored from a backup (`den_hub restore` left [restoreMarkerDoc]) and no approved device
  /// has synced with the hub since. What the hub wrote after the backup is still on the family's
  /// devices, under change ids this copy of the log doesn't hold; a change it wrote now could
  /// take one of those ids, and every replica would ignore the other's as a duplicate. So until a
  /// device has handed those changes back (den_core then numbers past them), the hub writes
  /// nothing of its own: no calendar feeds, no OAuth sweep or tokens, no API or MCP writes.
  bool get catchingUp => state.restored;

  /// Throws `503 catching_up` (with `Retry-After`) while [catchingUp].
  void requireCaughtUp() {
    if (catchingUp) throw ApiError.catchingUp();
  }

  /// The hub device's name.
  String get name => den.thisDevice?.name ?? config.name;

  /// The family's time zone.
  String get zone => den.family?.timezone ?? 'UTC';

  /// UTC milliseconds now.
  int now() => DateTime.now().toUtc().millisecondsSinceEpoch;

  /// Per-client limits on what strangers can do: the host's, shared by every family on it.
  final RateLimiter limits;

  /// The public base URL [request] came to (the configured public URL, else what a trusted
  /// proxy says, else the request's `Host`).
  Uri base(Request request) => requestBase(request, config.publicUrl, trusted: config.trustedProxies);

  /// Whether [request] reached the hub over HTTPS (at a trusted proxy, or by the public URL).
  bool secure(Request request) => base(request).scheme == 'https';

  /// The client [request] came from, through trusted proxies only.
  InternetAddress? client(Request request) => clientAddress(request, config.trustedProxies);

  /// The key [request]'s client is limited under (for a request the host answers in-process
  /// for a family's hub, that hub's own).
  String clientOf(Request request) => requestClientKey(request, config.trustedProxies);

  /// Takes one from [request]'s client's [name] budget, or throws `429 rate_limited`.
  void limit(Request request, String name, Rate rate, {String? message}) {
    final key = clientOf(request);
    if (limits.allow(name, key, rate)) return;
    final wait = limits.retryAfter(name, key, rate);
    throw message == null ? ApiError.rateLimited(wait) : ApiError.rateLimited(wait, message);
  }

  /// Throws `429 rate_limited` when [request]'s client has used up its failed tries.
  void checkFailures(Request request) {
    final key = clientOf(request);
    if (limits.exhausted('failures', key, Limits.failures)) {
      throw ApiError.rateLimited(limits.retryAfter('failures', key, Limits.failures));
    }
  }

  /// Counts a failed try (a bad token or signature) against [request]'s client.
  void failed(Request request) => limits.allow('failures', clientOf(request), Limits.failures);
}
