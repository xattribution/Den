import 'dart:async';

import 'package:den_net/den_net.dart';

import 'log.dart';

/// Runs the hub's relay mailbox rounds and says in the log when the relay turns the hub away:
/// a tunnel it won't take (`503`, the relay is full or this address has its share) or drops,
/// and mailbox posts or key deliveries it refuses (`507` when a cap is reached, `429`/`503`
/// when it is limiting). den_net tries again on its own (the tunnel with backoff, the mailbox
/// every round); this logs each new problem once, and when it clears.
class RelayWatch {
  /// Creates a watch logging to [log].
  RelayWatch(this.log);

  /// Where problems are reported.
  final HubLog log;

  StreamSubscription<TunnelStatus>? _tunnel;
  Timer? _timer;
  String? _tunnelProblem;
  String? _mailboxProblem;
  bool _stopped = false;

  /// Follows [tunnel]'s status.
  void watchTunnel(RelayTunnel tunnel) {
    _tunnel = tunnel.statusChanges.listen(tunnelStatus);
  }

  /// Logs a tunnel status: a new reason it is down, or that it is back.
  void tunnelStatus(TunnelStatus status) {
    switch (status.state) {
      case TunnelState.offline:
        final why = status.lastError ?? 'closed';
        if (why == _tunnelProblem) return;
        _tunnelProblem = why;
        log.warn('The relay didn\'t keep the hub\'s tunnel ($why${why.contains('503') ? ': the relay is full' : ''}). '
            'Devices away from home can\'t reach the hub through it until it is back; the hub keeps trying.');
      case TunnelState.online:
        if (_tunnelProblem != null) log.info('The relay tunnel is back');
        _tunnelProblem = null;
      case TunnelState.connecting:
      case TunnelState.stopped:
        break;
    }
  }

  /// Runs [mailbox] now and every [interval] until [stop].
  void runMailbox(MailboxSync mailbox, {Duration interval = const Duration(minutes: 1)}) {
    _timer = Timer.periodic(interval, (_) => unawaited(mailboxRound(mailbox.syncOnce)));
    unawaited(mailboxRound(mailbox.syncOnce));
  }

  /// One mailbox round through [syncOnce], logged when the relay refused part of it.
  Future<void> mailboxRound(Future<MailboxRound> Function() syncOnce) async {
    if (_stopped) return;
    String? problem;
    try {
      final round = await syncOnce();
      if (round.failed > 0) {
        problem = 'it refused or didn\'t take ${round.failed} of this round\'s mailbox posts and key deliveries';
      }
    } on RelayException catch (e) {
      problem = switch (e.status) {
        507 => 'it is full',
        429 || 503 => 'it is limiting this hub (${e.message})',
        _ => e.message,
      };
    } on Object catch (e) {
      problem = '$e';
    }
    if (problem == null) {
      if (_mailboxProblem != null) log.info('The relay mailboxes are working again');
      _mailboxProblem = null;
      return;
    }
    if (problem == _mailboxProblem) return;
    _mailboxProblem = problem;
    log.warn('The relay\'s mailboxes didn\'t take everything ($problem). Devices that only reach the relay may '
        'see changes late; the hub tries again every round.');
  }

  /// Stops the mailbox rounds and the tunnel watch.
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    await _tunnel?.cancel();
  }
}
