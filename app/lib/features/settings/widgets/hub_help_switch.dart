import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/pairing.dart';
import '../../family/family.dart';

/// Settings → Family, on a parent's own device: "Let the hub help us get back in". Off by
/// default. On, the hub's server recovery key goes into the family record, so whoever runs the
/// hub can let in a new phone for a parent who lost theirs (`den_hub recover`), and a parent's
/// passkey lets them straight back in (the hub signs the same proof); every device says when
/// that happens. Off, the key comes out and the hub can't any more: a parent's passkey then asks
/// another parent instead. Turning it on says what it means first. A parent who makes a passkey
/// on their own device turns it on in the same step, as the offer says.
class HubHelpSwitch extends StatefulWidget {
  const HubHelpSwitch({super.key});

  @override
  State<HubHelpSwitch> createState() => _HubHelpSwitchState();
}

class _HubHelpSwitchState extends State<HubHelpSwitch> {
  bool _asking = false;
  bool _busy = false;
  String? _error;

  Future<void> _set(bool on) async {
    final pairing = Pairing.of(context);
    final trust = context.trustActions;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? problem;
    try {
      final key = on ? await pairing.hubRecoveryKey() : null;
      problem = await tryWrite(() => trust.setHubHelp(key));
    } on PairingException catch (e) {
      problem = e.message;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
      if (problem == null) _asking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.family, RecordType.device});
    final den = app.den;
    final family = den.family;
    final on = family != null && serverRecoveryKeyOf(family) != null;
    final hub = den.devices.any((d) => d.mode == DeviceMode.hub && d.approved && !d.revoked);
    if (family == null || !app.allowsTrust(DenAction.manageFamily) || (!hub && !on)) return const SizedBox.shrink();
    return GroupCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchLine(
            label: 'Let the hub help us get back in',
            detail: on
                ? 'Whoever runs your hub can let in a new phone for a parent who lost theirs, and a parent\'s Face ID or '
                    'passkey lets them straight back in. Every device shows it when that happens.'
                : 'If a parent loses their phone and no other parent has theirs, whoever runs your hub could let a new one in.',
            value: on || _asking,
            onChanged: _busy
                ? null
                : (v) {
                    if (v && !on) {
                      setState(() {
                        _asking = true;
                        _error = null;
                      });
                    } else if (!v && _asking) {
                      setState(() => _asking = false);
                    } else if (!v) {
                      _set(false);
                    }
                  },
          ),
          DenReveal(
            visible: _asking,
            child: !_asking
                ? const SizedBox(width: double.infinity)
                : ConfirmPanel(
                    message: 'Whoever runs your hub could then add a phone as any parent in the family, '
                        'without your words. Every device in the family would show it. You can turn this off any time.',
                    confirmLabel: 'Turn it on',
                    busy: _busy,
                    error: _error,
                    onConfirm: () => _set(true),
                    onCancel: () => setState(() {
                      _asking = false;
                      _error = null;
                    }),
                  ),
          ),
          if (_error != null && !_asking) ...[
            ErrorState(message: _error!, actionLabel: 'OK', onAction: () => setState(() => _error = null)),
            const SizedBox(height: Sp.m),
          ],
        ],
      ),
    );
  }
}
