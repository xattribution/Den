import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../family/family.dart';
import '../../shared_screens/shared_screens.dart';

/// Advanced → Shared displays: the screens the whole family uses (a tablet on the counter, a
/// screen on the wall), what each shows, whether anyone there may check things off without a
/// PIN, and removing one. This device can be a wall display too. A new display joins with an
/// invite that names nobody, and a parent lets it in as a shared display.
class DisplaysScreen extends StatefulWidget {
  const DisplaysScreen({super.key});

  @override
  State<DisplaysScreen> createState() => _DisplaysScreenState();
}

class _DisplaysScreenState extends State<DisplaysScreen> {
  String? _removing;
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<Object?> Function() write) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await tryWrite(write);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
      if (problem == null) _removing = null;
    });
  }

  void _display(Device device, Map<String, Object?> change) {
    final trust = context.trustActions;
    _run(() => trust.setDisplay(device.id, {...device.rec.map('display'), ...change}));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final trust = app.allowsTrust(DenAction.manageFamily);
    final displays = sharedDisplays(app.den);
    final me = app.me;
    final needsPin = me != null && me.isParent && me.signIn.kind == 'none' && displays.isNotEmpty;
    return DenPage(
      title: 'Shared displays',
      children: [
        if (!trust)
          const NoticeLine(
            icon: PhosphorIconsRegular.lockKey,
            message: "Shared displays change only on a parent's own phone.",
          ),
        if (needsPin && trust)
          GroupCard(
            child: ActionRow(
              leading: SizedBox.square(dimension: 40, child: Icon(PhosphorIconsRegular.lockKey, size: 26, color: c.ink)),
              title: 'Set your PIN for shared screens',
              detail: 'So nobody at ${displays.first.name} can act as you',
              action: FilledButton(onPressed: () => showSignInSheet(context, me), child: const Text('Set PIN')),
            ),
          ),
        for (final d in displays) _displayCard(context, d, trust: trust),
        DenSection(
          title: displays.isEmpty ? 'Add a display' : 'Another display',
          child: EmptyState(
            compact: true,
            message: displays.isEmpty
                ? 'No shared displays yet. Open Den on the tablet, join with an invite, then let it in here as a shared display.'
                : 'Open Den on it, join with an invite, then let it in as a shared display.',
            actionLabel: trust ? 'Invite a display' : null,
            onAction: trust ? () => showInviteSheet(context, shared: true) : null,
          ),
        ),
        DenSection(
          title: 'This device',
          child: SwitchLine(
            label: 'Use as a wall display',
            detail: 'Larger type, and the family week first',
            value: app.wall,
            onChanged: (on) => app.wall = on,
          ),
        ),
      ],
    );
  }

  Widget _displayCard(BuildContext context, Device d, {required bool trust}) {
    final removing = _removing == d.id;
    return DenSection(
      title: d.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceRows<DisplayLayout>(
            choices: const [
              Choice(DisplayLayout.week, 'The week', detail: 'A column for each person'),
              Choice(DisplayLayout.today, 'Today', detail: "Each person's plans and chores for today"),
            ],
            value: wallLayoutOf(d),
            onChanged: trust && !_busy ? (l) => _display(d, {'layout': l.name}) : null,
          ),
          const RowRule(),
          SwitchLine(
            label: 'Anyone there can check things off',
            detail: d.openCheckoff
                ? 'Chores and groceries, without a PIN. History says they were done on ${d.name}.'
                : 'Off: people choose who they are and use their PIN',
            value: d.openCheckoff,
            onChanged: trust && !_busy ? (on) => _display(d, {'openCheckoff': on}) : null,
          ),
          if (trust) ...[
            const RowRule(),
            if (!removing)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _removing = d.id),
                  style: TextButton.styleFrom(foregroundColor: context.colors.destructive),
                  icon: Icon(PhosphorIconsRegular.trash, size: 20, color: context.colors.destructive),
                  label: Text('Remove ${d.name}'),
                ),
              ),
            DenReveal(
              visible: removing,
              child: !removing
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: Sp.m),
                      child: ConfirmPanel(
                        message: '${d.name} stops syncing right away and forgets the family. To use it again, invite it.',
                        confirmLabel: 'Remove ${d.name}',
                        destructive: true,
                        busy: _busy,
                        error: _error,
                        onConfirm: () {
                          final trustActions = context.trustActions;
                          _run(() => trustActions.revokeDevice(d.id));
                        },
                        onCancel: () => setState(() => _removing = null),
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

