/// The Den hub: the family's always-on device. HTTP API and event stream, WebSocket sync, MCP
/// with OAuth for remote clients, calendar feeds in and out, reminders through Home Assistant
/// and ntfy, and mDNS advertising, on one port.
///
/// Start one over an open [Den] with [DenHub.start]; it also runs in-process inside the Den app.
library;

export 'src/access.dart' show Access, accessForToken, readableSpacesFor;
export 'src/capture.dart' show HubCapture;
export 'src/config.dart';
export 'src/edge.dart' show IpNetwork;
export 'src/hub.dart';
export 'src/log.dart';
export 'src/setup.dart' show SetupStage, setupAlphabet, setupTries, restrictToOwner;
export 'src/times.dart' show parseInstant, isoIn;
export 'src/mcp/server.dart' show McpServer, mcpProtocolVersions;
export 'src/mcp/stdio.dart' show serveMcpStdio;
export 'src/ics/expand.dart' show expandCalendar, groupSeries, IcsOccurrence, IcsSeries;
export 'src/ics/feeds.dart' show FeedService;
export 'src/ics/parse.dart' show parseIcs, parseIcsDuration, zoneForTzid, IcsCalendar, IcsEvent, IcsTime, IcsFormatException;
export 'src/reminders.dart' show ReminderService, Notice;
export 'src/mdns/dns.dart' show DnsMessage, DnsQuestion, DnsRecord, DnsType;
export 'src/mdns/responder.dart' show MdnsAdvert, MdnsResponder, denServiceName;
