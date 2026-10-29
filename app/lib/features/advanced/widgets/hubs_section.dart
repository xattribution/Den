import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../app/format.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/den_network.dart';
import '../../family/family.dart';

/// Advanced → Hub and sync → the family's hubs: the one this device syncs with first, when it
/// last synced with each, and, for a parent on their own device, Remove. After "reset the hub,
/// keep the family" the old hub stays listed, often under the same name, until someone removes
/// it; "Added" tells the two apart.
class HubsSection extends StatefulWidget {
  const HubsSection({super.key});

  @override
  State<HubsSection> createState() => _HubsSectionState();
}

class _HubsSectionState extends State<HubsSection> {
  String? _removing;
  bool _busy = false;
  String? _error;

  /// Revokes [hub]. A connection to it ends on its own: the sync client tells it it was removed
  /// and goes on to the next hub.
  Future<void> _remove(Device hub) async {
    final trust = context.trustActions;
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await tryWrite(() => trust.revokeDevice(hub.id));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
      if (problem == null) _removing = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final network = app.network;
    if (network == null) return const SizedBox.shrink();
    final trust = app.allowsTrust(DenAction.manageFamily);
    return ListenableBuilder(
      listenable: network,
      builder: (context, _) {
        final hubs = network.hubDevices;
        return DenSection(
          title: hubs.length == 1 ? 'The hub' : 'Hubs',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: ruled([
              for (final hub in hubs) _row(context, app.formats, network, hub, trust: trust),
            ], indent: 36),
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, Formats f, DenNetwork network, Device hub, {required bool trust}) {
    final c = context.colors;
    final t = context.text;
    final removing = _removing == hub.id;
    final now = network.den.now();
    final seen = network.lastSeen(hub.id);
    final added = (hub.rec.fieldTimes['approved'] ?? hub.rec.updated).millis;
    final detail = [
      network.syncedWith(hub.id)
          ? 'This device syncs with it now'
          : seen == null
          ? 'Not seen from this device'
          : 'Last seen ${seenWords(f, seen.millisecondsSinceEpoch, now)}',
      'Added ${DateFormat.MMMd().format(f.at(added))}',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.s),
            child: Row(
              children: [
                Icon(PhosphorIconsRegular.hardDrives, size: 22, color: c.ink),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(hub.name, style: t.body(c.ink)),
                      Text(detail, style: t.meta(c.ink2)),
                    ],
                  ),
                ),
                if (trust && !removing)
                  TextButton(
                    onPressed: _busy ? null : () => setState(() => _removing = hub.id),
                    style: TextButton.styleFrom(foregroundColor: c.destructive),
                    child: const Text('Remove', maxLines: 1, softWrap: false),
                  ),
              ],
            ),
          ),
        ),
        DenReveal(
          visible: removing,
          child: !removing
              ? const SizedBox(width: double.infinity)
              : ConfirmPanel(
                  message: removeHubWords(hub.name, last: network.hubDevices.length == 1),
                  confirmLabel: 'Remove ${hub.name}',
                  destructive: true,
                  busy: _busy,
                  error: _error,
                  onConfirm: () => _remove(hub),
                  onCancel: () => setState(() {
                    _removing = null;
                    _error = null;
                  }),
                ),
        ),
      ],
    );
  }
}

/// What removing a hub does, said before it does it.
String removeHubWords(String name, {required bool last}) =>
    '$name stops syncing with the family, and the family\'s devices stop looking for it. '
    '${last ? 'Until you add another hub, devices sync with each other when they meet. ' : ''}'
    'To use it again, reset it and add it as a new hub.';

/// "today at 9:41 AM", "yesterday at 6:05 PM", "Oct 3".
String seenWords(Formats f, int ms, int now) {
  final day = f.relative(f.localDate(ms), f.localDate(now));
  return switch (day) {
    'Today' || 'Yesterday' => '${day.toLowerCase()} at ${f.time(ms)}',
    _ => DateFormat.MMMd().format(f.at(ms)),
  };
}
