import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/pairing.dart';
import '../../../platform/web/web_app.dart';
import '../../family/family.dart';

/// After a join request: the matching words to compare with the parent's screen, and where the
/// request stands. Approval arrives by sync, also after Den was closed and opened again; the
/// router then moves on to Today. Start over withdraws the request, for a new invite. A device
/// an invite let in by itself ([JoinTicket.admitted]) only catches up here, for a moment.
class WaitingScreen extends StatefulWidget {
  const WaitingScreen({super.key, this.ticket});

  /// The join being waited on; defaults to the one this device sent last.
  final JoinTicket? ticket;

  @override
  State<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<WaitingScreen> {
  bool _startingOver = false;

  Future<void> _startOver() async {
    final den = DenScope.read(context).den;
    await attempt(context, den.leaveFamily);
    // A browser opens again as a fresh device, with new keys (see Boot).
    if (Capabilities.web) WebApp.reload();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final ticket = widget.ticket ?? Pairing.ticket;
    final words = ticket?.words ?? const <String>[];
    final app = context.watch(const {});
    final device = app.den.thisDevice?.name;
    final other = ticket?.inviterName ?? "the parent's screen";
    final admitted = ticket?.admitted ?? false;

    return DenPage(
      title: admitted ? 'Joining your family' : 'Waiting for approval',
      back: false,
      children: [
        if (words.isNotEmpty)
          DenSection(
            title: 'Check these words match on $other',
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.l),
              child: Semantics(
                label: words.join(', '),
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final w in words) Text(w, style: t.display(c.ink))],
                ),
              ),
            ),
          ),
        StreamBuilder<JoinStatus>(
          stream: Pairing.of(context).joinStatus,
          builder: (context, snap) {
            final status = snap.data;
            if (status?.state == JoinState.approved) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) context.go('/today');
              });
            }
            // Still holding the family's request: the way out is to start over. Not holding it:
            // join again.
            final holding = app.den.hasFamily;
            return switch (status?.state) {
              JoinState.declined => ErrorState(
                  message: status?.message ?? 'A parent turned this device away. Ask them for a new invite.',
                  actionLabel: holding ? 'Start over' : 'Try again',
                  onAction: holding ? () => setState(() => _startingOver = true) : () => context.go('/welcome/join'),
                ),
              JoinState.failed when !holding => ErrorState(
                  message: status?.message ?? "Lost touch with the family's devices.",
                  actionLabel: 'Try again',
                  onAction: () => context.go('/welcome/join'),
                ),
              JoinState.failed => NoticeLine(
                  message: status?.message ?? "Lost touch with the family's devices. Keep Den open; it will try again.",
                ),
              _ when admitted => NoticeLine(
                  icon: PhosphorIconsRegular.hourglass,
                  message: device == null ? 'Letting this device in' : 'Letting $device in',
                ),
              _ => NoticeLine(
                  icon: PhosphorIconsRegular.hourglass,
                  message: device == null
                      ? 'Waiting for a parent to let this device in'
                      : 'Waiting for a parent to let $device in',
                ),
            };
          },
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_startingOver)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _startingOver = true),
                  child: const Text('Start over with a new invite'),
                ),
              ),
            DenReveal(
              visible: _startingOver,
              child: !_startingOver
                  ? const SizedBox(width: double.infinity)
                  : ConfirmPanel(
                      message: 'This device stops asking to join. Ask a parent for a new invite to join again.',
                      confirmLabel: 'Start over',
                      onConfirm: _startOver,
                      onCancel: () => setState(() => _startingOver = false),
                    ),
            ),
          ],
        ),
      ],
    );
  }
}
