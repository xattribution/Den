import 'package:den_net/relay_protocol.dart';

/// A token bucket's shape: up to [capacity] requests at once, refilled at [perSecond].
class RateSpec {
  /// Creates a rate.
  const RateSpec({required this.capacity, required this.perSecond});

  /// Burst size.
  final double capacity;

  /// Sustained requests per second.
  final double perSecond;
}

/// Everything the relay can be tuned with. Defaults suit a public relay for many families.
class RelayConfig {
  /// Creates a configuration.
  const RelayConfig({
    this.dataDir = 'data',
    this.trustProxy = false,
    this.mailboxTtl = const Duration(days: 30),
    this.sweepInterval = const Duration(hours: 1),
    this.maxBlobBytes = maxRelayMessageBytes,
    this.maxMailboxBytes = 32 * 1024 * 1024,
    this.maxMailboxEntries = 10000,
    this.maxMailboxes = 100000,
    this.maxTotalBytes = 10 * 1024 * 1024 * 1024,
    this.readPageEntries = 200,
    this.readPageBytes = 8 * 1024 * 1024,
    this.slotTtl = const Duration(minutes: 15),
    this.maxSlots = 10000,
    this.maxTunnels = 10000,
    this.maxStreamsPerTunnel = 64,
    this.maxMessageBytes = maxRelayMessageBytes,
    this.ipRate = const RateSpec(capacity: 120, perSecond: 20),
    this.mailboxWriteRate = const RateSpec(capacity: 120, perSecond: 2),
    this.mailboxReadRate = const RateSpec(capacity: 240, perSecond: 4),
    this.authTimeout = const Duration(seconds: 10),
    this.pingInterval = const Duration(seconds: 30),
    this.now,
  });

  /// Where mailboxes are persisted.
  final String dataDir;

  /// Honor `X-Forwarded-For` (its last entry, the address the trusted proxy saw). Only behind a
  /// reverse proxy that sets it; otherwise clients could pick their own rate-limit key.
  final bool trustProxy;

  /// How long mailbox blobs are kept.
  final Duration mailboxTtl;

  /// How often expired blobs are swept.
  final Duration sweepInterval;

  /// Largest mailbox blob.
  final int maxBlobBytes;

  /// Most bytes one mailbox may hold.
  final int maxMailboxBytes;

  /// Most blobs one mailbox may hold.
  final int maxMailboxEntries;

  /// Most mailboxes the relay holds.
  final int maxMailboxes;

  /// Most bytes across every mailbox.
  final int maxTotalBytes;

  /// Most blobs returned by one read.
  final int readPageEntries;

  /// Most bytes returned by one read (at least one blob is always returned).
  final int readPageBytes;

  /// How long a rendezvous host waits for its guest.
  final Duration slotTtl;

  /// Most rendezvous hosts waiting at once.
  final int maxSlots;

  /// Most hub tunnels open at once.
  final int maxTunnels;

  /// Most client streams through one hub's tunnel.
  final int maxStreamsPerTunnel;

  /// Largest WebSocket message forwarded.
  final int maxMessageBytes;

  /// Requests per client address.
  final RateSpec ipRate;

  /// Appends per mailbox.
  final RateSpec mailboxWriteRate;

  /// Reads per mailbox.
  final RateSpec mailboxReadRate;

  /// How long a hub has to answer the tunnel challenge.
  final Duration authTimeout;

  /// WebSocket ping interval, so dead peers are noticed.
  final Duration? pingInterval;

  /// Clock in UTC milliseconds; injectable for tests.
  final int Function()? now;

  /// The current time in UTC milliseconds.
  int currentMillis() => now?.call() ?? DateTime.now().millisecondsSinceEpoch;

  /// A copy with some fields replaced.
  RelayConfig copyWith({String? dataDir, bool? trustProxy}) => RelayConfig(
        dataDir: dataDir ?? this.dataDir,
        trustProxy: trustProxy ?? this.trustProxy,
        mailboxTtl: mailboxTtl,
        sweepInterval: sweepInterval,
        maxBlobBytes: maxBlobBytes,
        maxMailboxBytes: maxMailboxBytes,
        maxMailboxEntries: maxMailboxEntries,
        maxMailboxes: maxMailboxes,
        maxTotalBytes: maxTotalBytes,
        readPageEntries: readPageEntries,
        readPageBytes: readPageBytes,
        slotTtl: slotTtl,
        maxSlots: maxSlots,
        maxTunnels: maxTunnels,
        maxStreamsPerTunnel: maxStreamsPerTunnel,
        maxMessageBytes: maxMessageBytes,
        ipRate: ipRate,
        mailboxWriteRate: mailboxWriteRate,
        mailboxReadRate: mailboxReadRate,
        authTimeout: authTimeout,
        pingInterval: pingInterval,
        now: now,
      );
}
