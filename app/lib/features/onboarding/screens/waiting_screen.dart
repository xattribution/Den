import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/pairing.dart';
import '../../../app/app_state.dart';
import '../../../platform/web/web_app.dart';
import '../../../platform/capabilities.dart';
import '../../../design/forms/forms.dart';

/// After a join request: the matching words to compare with the parent's screen, and where the
/// request stands. Approval arrives by sync, also after Den was closed and opened again; the
/// router then moves on to Today. Start over withdraws the request, for a new invite.
class WaitingScreen extends StatelessWidget {
  const WaitingScreen({super.key, this.ticket});

  /// The join being waited on; defaults to the one this device sent last.
  final JoinTicket? ticket;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = ticket ?? Pairing.ticket;
    final words = t?.words ?? const <String>[];
    final device = context.den.thisDevice?.name;
    final other = t?.inviterName ?? 'the other screen';

    return FormFrame(
      title: 'Waiting for approval',
      back: false,
      children: [
        if (words.isNotEmpty) ...[
          FormBlock(child: Text('Check these words match on $other:', style: context.type.body(c.ink))),
          FormBlock(
            top: Sp.m,
            child: Semantics(
              label: words.join(', '),
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final w in words) Text(w, style: context.type.display(c.ink))],
              ),
            ),
          ),
        ],
        StreamBuilder<JoinStatus>(
          stream: Pairing.of(context).joinStatus,
          builder: (context, snap) {
            final status = snap.data;
            if (status?.state == JoinState.approved) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) context.go('/today');
              });
            }
            final ended = status?.state == JoinState.declined || status?.state == JoinState.failed;
            final line = FormBlock(
              top: Sp.xl,
              child: switch (status?.state) {
                JoinState.declined => AttentionLine(
                  bad: true,
                  message: status?.message ?? 'A parent declined this device. Ask them to add it again.',
                ),
                JoinState.failed => AttentionLine(
                  bad: true,
                  message: status?.message ?? "Lost touch with the family's devices. Keep Den open; it will try again.",
                ),
                _ => Row(
                  children: [
                    Icon(PhosphorIconsRegular.hourglass, size: 20, color: c.ink2),
                    const SizedBox(width: Sp.m),
                    Expanded(
                      child: Text(
                        device == null
                            ? 'Waiting for a parent to approve this device'
                            : 'Waiting for a parent to approve $device',
                        style: context.type.body(c.ink2),
                      ),
                    ),
                  ],
                ),
              },
            );
            if (!ended || context.den.hasFamily) return line;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                line,
                FormBlock(
                  top: Sp.m,
                  child: OutlinedButton(onPressed: () => context.go('/welcome/join'), child: const Text('Try again')),
                ),
              ],
            );
          },
        ),
        FormBlock(
          top: Sp.xl,
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => _startOver(context), child: const Text('Start over with a new invite')),
          ),
        ),
      ],
    );
  }

  Future<void> _startOver(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Start over?'),
        content: const Text('This device stops asking to join. Ask a parent for a new invite to join again.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Keep waiting')),
          FilledButton(onPressed: () => Navigator.of(dialog).pop(true), child: const Text('Start over')),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    final den = context.den;
    await attempt(context, den.leaveFamily);
    // A browser opens again as a fresh device, with new keys (see Boot).
    if (Capabilities.web) WebApp.reload();
  }
}
