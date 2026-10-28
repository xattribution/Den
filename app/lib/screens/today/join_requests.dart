import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import '../family/device_parts.dart';

/// Devices asking to join, at the top of Today for parents on their own devices (a shared screen
/// can't approve anyone). A device whose invite named a person is approved for them with one
/// tap; one that names nobody asks whose it is first.
class JoinRequests extends StatelessWidget {
  const JoinRequests({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (!app.allowsTrust(DenAction.manageFamily)) return const SizedBox.shrink();
    final waiting = app.den.pendingDevices;
    if (waiting.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final d in waiting) _Request(d)],
    );
  }
}

class _Request extends StatelessWidget {
  const _Request(this.device);
  final Device device;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final den = context.den;
    final who = device.member == null ? null : den.member(device.member!);
    return Container(
      decoration: BoxDecoration(
        color: c.well,
        border: Border(bottom: BorderSide(color: c.rule)),
      ),
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AttentionLine(message: who == null ? '${device.name} wants to join' : '${device.name} wants to join as ${who.name}'),
          const SizedBox(height: Sp.s),
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              FilledButton(
                onPressed: () => who == null
                    ? approveDevice(context, device.id, device.name)
                    : attempt(context, () => den.approveDevice(device.id, member: who.id, mode: DeviceMode.personal)),
                child: Text('Approve ${device.name}'),
              ),
              OutlinedButton(
                onPressed: () => attempt(context, () => den.revokeDevice(device.id)),
                child: const Text('Decline'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
