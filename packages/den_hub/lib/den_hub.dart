/// The Den hub: the family's always-on device. HTTP API and event stream, WebSocket sync, MCP
/// with OAuth for remote clients, calendar feeds in and out, reminders through Web Push, signing
/// in with Google and Apple, and mDNS advertising, on one port.
///
/// Start one over an open [Den] with [DenHub.start]; it also runs in-process inside the Den app.
library;

export 'package:den_actions/den_actions.dart' show readableSpacesFor;
export 'package:den_actions/times.dart' show parseInstant, isoIn;
export 'src/access.dart' show Access, accessForToken;
export 'src/accounts.dart' show HubAccounts;
export 'src/oidc.dart'
    show
        AppleKey,
        ClientCheck,
        Jwt,
        OidcEndpoints,
        OidcIdentity,
        OidcProvider,
        OidcRefusal,
        OidcRefused,
        RsaPublicKey,
        SignInProviders,
        appleClientSecret,
        appleProvider,
        appleRelayDomain,
        googleProvider,
        parseJwks,
        pkceChallenge,
        pkcs1Sha256,
        randomToken,
        readP8,
        rsaVerifySha256;
export 'src/sign_in_setup.dart'
    show
        AppleClient,
        GoogleClient,
        HostSignIn,
        HubSignInSetup,
        appleServicesIdProblem,
        appleTenProblem,
        googleClientIdProblem,
        googleSecretProblem,
        signInFile;
export 'src/assistant.dart' show HubAssistant;
export 'src/capture.dart' show HubCapture;
export 'src/config.dart';
export 'src/edge.dart' show IpNetwork;
export 'src/host.dart' show DenHost, HostConfig, HostedTenant;
export 'src/host_state.dart'
    show HostState, HostedLog, hostCliFile, hostLogsDir, hostPushFile, hostStateDir, normalizeHostname, requestHostname;
export 'src/hub.dart';
export 'src/tenant_router.dart' show RoutableLog, TenantRouter;
export 'src/log.dart';
export 'src/net_guard.dart' show BlockedAddress, HostResolver, NetGuard, isPublicAddress, parsePeerHubs, systemResolver;
export 'src/setup.dart' show HubSetup, SetupStage, setupAlphabet, setupLink, setupTries, restrictToOwner, linkOpenFile, removedNotice;
export 'src/mcp/http.dart' show decodeMcpHeader, encodeMcpHeader, mcpRequestHeaders;
export 'src/mcp/server.dart'
    show McpMeta, McpReply, McpServer, RpcError, legacyProtocolVersions, mcpProtocolVersions, modernProtocolVersions;
export 'src/mcp/stdio.dart' show serveMcpStdio;
export 'src/ics/expand.dart' show expandCalendar, groupSeries, IcsOccurrence, IcsSeries;
export 'src/ics/feeds.dart' show FeedService, familyPhrase, sharePoll;
export 'src/ics/watch.dart' show shareWatchUri;
export 'src/ics/write.dart' show icsEtag, isDenUid;
export 'src/ics/parse.dart' show parseIcs, parseIcsDuration, zoneForTzid, IcsCalendar, IcsEvent, IcsTime, IcsFormatException;
export 'src/recovery.dart' show HubRecovery, RecoveryRefused, RecoveryTicket, recoveryCliFile, recoveryTicketsDoc;
export 'src/reminders.dart' show ReminderService, ReminderSink;
export 'src/screen_codes.dart' show ScreenCodes;
export 'src/mdns/dns.dart' show DnsMessage, DnsQuestion, DnsRecord, DnsType;
export 'src/mdns/responder.dart' show MdnsAdvert, MdnsResponder, denServiceName;
