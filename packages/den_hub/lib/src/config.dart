import 'dart:io';

import 'package:http/http.dart' as http;

import 'edge.dart';
import 'log.dart';
import 'net_guard.dart';

/// The hub's default port, shared by HTTP, WebSocket sync and MCP.
const int defaultHubPort = 47733;

/// The `den_hub` version reported by `/health`, mDNS and MCP.
const String hubVersion = '0.1.0';

/// Where one member's reminders go.
class MemberNotify {
  /// Creates a member's notifier targets; either may be null.
  const MemberNotify({this.homeAssistantService, this.ntfyTopic});

  /// Reads `{"ha": "mobile_app_alex_phone", "ntfy": "https://ntfy.sh/den-alex"}`.
  factory MemberNotify.fromJson(Map<String, Object?> json) => MemberNotify(
        homeAssistantService: json['ha'] as String?,
        ntfyTopic: json['ntfy'] as String?,
      );

  /// Home Assistant notify service name, without `notify.` (`mobile_app_alex_phone`).
  final String? homeAssistantService;

  /// ntfy topic: a full URL (`https://ntfy.sh/den-alex-7f3k`), or a topic name on ntfy.sh.
  final String? ntfyTopic;
}

/// How a hub runs. Everything is optional; the defaults serve a family on the LAN.
class HubConfig {
  /// Creates a configuration.
  const HubConfig({
    this.port = defaultHubPort,
    this.host,
    this.dataDir,
    this.webDir,
    this.relay,
    this.name = 'Den hub',
    this.homeAssistantUrl,
    this.homeAssistantToken,
    this.notify = const {},
    this.publicUrl,
    this.allowedOrigins = const [],
    this.trustedProxies = const [],
    this.public,
    this.contentSecurityPolicy,
    this.mailbox = false,
    this.mdns = true,
    this.log,
    this.httpClient,
    this.fetchAllow = const [],
    this.resolver,
    this.fetchClient,
    this.feedInterval = const Duration(minutes: 30),
    this.reminderInterval = const Duration(minutes: 1),
    this.accessTokenLifetime = const Duration(hours: 1),
    this.refreshTokenLifetime = const Duration(days: 90),
    this.onSetupCode,
  });

  /// TCP port for HTTP, WebSocket sync and MCP; 0 picks a free one.
  final int port;

  /// Address to bind (an [InternetAddress] or a string); default every IPv4 interface.
  final Object? host;

  /// Directory for the hub's own state (reminders sent, OAuth clients and refresh tokens,
  /// calendar feed caches). Null keeps that state in memory only. The change log is the
  /// caller's [Den] storage, not this.
  final String? dataDir;

  /// A static web build (Flutter `build/web`) served at `/` with single-page fallback; null
  /// serves no web app.
  final String? webDir;

  /// A relay (`https://relay.den.family`) for a tunnel, so devices reach the hub from anywhere.
  final Uri? relay;

  /// The hub's device name before it joins a family (afterwards, its device record's name).
  final String name;

  /// Home Assistant's base URL for notifications (`http://homeassistant.local:8123`).
  final Uri? homeAssistantUrl;

  /// A Home Assistant long-lived access token.
  final String? homeAssistantToken;

  /// Reminder targets by member id or member name.
  final Map<String, MemberNotify> notify;

  /// The hub's public base URL (`https://den.example.com`), used for OAuth metadata and link
  /// codes. Without it the hub uses the address each request came to.
  final Uri? publicUrl;

  /// Extra browser origins allowed to call `/mcp` and OAuth endpoints (`https://claude.ai`).
  final List<String> allowedOrigins;

  /// Reverse proxies whose `X-Forwarded-For`, `-Proto` and `-Host` the hub believes
  /// (`DEN_TRUSTED_PROXIES`). From anyone else those headers are ignored, so per-client limits
  /// and the public URL can't be spoofed.
  final List<IpNetwork> trustedProxies;

  /// The public posture, for a hub reachable from the internet (`DEN_PUBLIC`): `/health` says
  /// nothing that identifies the hub or family, `/api/v1/hub/status` says only whether it is
  /// paired once it is, and browsers can ask to be linked only while a parent has opened
  /// "Add a device". Null decides by [publicUrl]: on for an `https` public URL.
  final bool? public;

  /// Replaces the Content-Security-Policy the hub sends with the web app (`DEN_CSP`), for a web
  /// build that needs more than the default allows. Null keeps the default.
  final String? contentSecurityPolicy;

  /// Whether the hub runs in the public posture (see [public]).
  bool get publicPosture => public ?? (publicUrl?.scheme == 'https');

  /// Also sync through the relay's mailboxes, for devices that only reach the relay.
  final bool mailbox;

  /// Advertise `_den._tcp` on the LAN.
  final bool mdns;

  /// Where the hub logs; default info and above to standard error.
  final HubLog? log;

  /// HTTP client for what the operator configured: notifiers, the capture reader, the
  /// assistant's provider (tests pass their own). Addresses callers give the hub (calendar
  /// feeds, OAuth client metadata) go through [NetGuard] instead.
  final http.Client? httpClient;

  /// Networks the hub may fetch callers' addresses from although they aren't on the public
  /// internet (`DEN_FETCH_ALLOW`, addresses or CIDRs): a calendar server at home. Empty by
  /// default, so a feed or a redirect can't reach the hub's own machine or network.
  final List<IpNetwork> fetchAllow;

  /// Looks host names up for those fetches; null is the system's resolver (tests pass a fake).
  final HostResolver? resolver;

  /// Replaces the guarded client for those fetches altogether: for tests that serve a client
  /// metadata document from a fake https address. Null in real use.
  final http.Client? fetchClient;

  /// How often calendar feeds are fetched.
  final Duration feedInterval;

  /// How often reminders are computed.
  final Duration reminderInterval;

  /// How long an OAuth access token works before the client refreshes it.
  final Duration accessTokenLifetime;

  /// How long an unused OAuth refresh token works.
  final Duration refreshTokenLifetime;

  /// Called with each new setup code while the hub has no family (an app showing it on screen).
  final void Function(String code)? onSetupCode;

  /// The bind address as an [InternetAddress] or string for `HttpServer.bind`.
  Object get bindAddress => host ?? InternetAddress.anyIPv4;
}
