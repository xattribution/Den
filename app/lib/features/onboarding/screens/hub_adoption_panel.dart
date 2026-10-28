import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/pairing.dart';
import '../../../app/app_state.dart';
import '../../../platform/capabilities.dart';
import '../../../design/forms/forms.dart';

/// In a browser that just started the family: how taking in the hub that served the page goes,
/// and, when the setup code was wrong or the page reloaded before it finished, a field to enter
/// it again. Shows nothing once the family has its hub, or where there's no hub to take in.
class HubAdoptionPanel extends StatefulWidget {
  const HubAdoptionPanel({super.key, this.hub});

  /// The fresh hub that served this page, for tests; by default asked of the hub on the web.
  final HubInfo? hub;

  @override
  State<HubAdoptionPanel> createState() => _HubAdoptionPanelState();
}

class _HubAdoptionPanelState extends State<HubAdoptionPanel> {
  final _code = TextEditingController();
  HubInfo? _hub;
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    _hub = widget.hub ?? Pairing.adoption.value?.hub;
    if (_hub == null && Capabilities.web) {
      Pairing.of(context).servingHub().then((hub) {
        if (mounted) setState(() => _hub = hub);
      });
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _start(HubInfo hub) {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    try {
      Pairing.adoption.value = Pairing.of(context).adoptServingHub(hub, code);
    } on PairingException catch (e) {
      showNote(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HubSetupSession?>(
      valueListenable: Pairing.adoption,
      builder: (context, session, _) {
        if (session == null) return _codeEntry(context, null);
        return ListenableBuilder(listenable: session, builder: (context, _) => _progress(context, session));
      },
    );
  }

  Widget _progress(BuildContext context, HubSetupSession session) {
    final c = context.colors;
    final name = session.hub.name;
    Widget line(IconData icon, String text) => FormBlock(
          top: 0,
          child: Row(
            children: [
              Icon(icon, size: 20, color: c.ink2),
              const SizedBox(width: Sp.m),
              Expanded(child: Text(text, style: context.type.body(c.ink2))),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Your hub'),
        switch (session.stage) {
          HubSetupStage.sending || HubSetupStage.waiting => line(PhosphorIconsRegular.hourglass, 'Adding $name to the family'),
          HubSetupStage.approving => line(PhosphorIconsRegular.hourglass, '$name is catching up with the family'),
          HubSetupStage.done => line(PhosphorIconsBold.check, '$name keeps the family in sync'),
          HubSetupStage.confirm => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FormBlock(top: 0, child: Text(session.words.join('  '), style: context.type.heading(c.ink))),
                FormBlock(
                  top: Sp.m,
                  child: FilledButton(
                    onPressed: session.wordsMatch == false ? null : session.approve,
                    child: Text('Approve $name'),
                  ),
                ),
              ],
            ),
          HubSetupStage.failed => _codeEntry(context, session.error, hub: session.hub, header: false),
        },
      ],
    );
  }

  Widget _codeEntry(BuildContext context, String? error, {HubInfo? hub, bool header = true}) {
    final target = hub ?? _hub;
    final den = context.den;
    final hasHub = den.devices.any((d) => d.approved && !d.revoked && d.mode == DeviceMode.hub && d.id != den.deviceId);
    if (target == null || hasHub || (error == null && (target.paired || target.stage != 'waiting_for_code'))) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header) const SectionHeader('Your hub'),
        if (error != null) FormBlock(top: 0, child: AttentionLine(message: error, bad: true)),
        FormBlock(
          top: error == null ? 0 : Sp.s,
          child: TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: 'Setup code for ${target.name}', hintText: 'ABCD-EFGH'),
            onSubmitted: (_) => _start(target),
          ),
        ),
        FormBlock(
          top: Sp.s,
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(onPressed: () => _start(target), child: Text('Add ${target.name}')),
          ),
        ),
      ],
    );
  }
}
