import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/pairing.dart';

/// In a browser that just started the family: how taking in the hub that served the page goes,
/// and, when the setup code was wrong or the page reloaded before it finished, a field to enter
/// it again. Shows nothing once the family has its hub, or where there's no hub to take in. It
/// keeps its own gap under it.
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
  String? _error;

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
      setState(() => _error = null);
    } on PairingException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HubSetupSession?>(
      valueListenable: Pairing.adoption,
      builder: (context, session, _) {
        if (session == null) return _framed(_codeEntry(context, _error));
        return ListenableBuilder(listenable: session, builder: (context, _) => _framed(_progress(context, session)));
      },
    );
  }

  Widget _framed(Widget? child) => child == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: DenLayout.sectionGap),
          child: DenSection(title: 'Your hub', carded: false, child: child),
        );

  Widget? _progress(BuildContext context, HubSetupSession session) {
    final name = session.hub.name;
    Widget line(IconData icon, String text) => GroupCard(child: NoticeLine(icon: icon, message: text));
    return switch (session.stage) {
      HubSetupStage.sending || HubSetupStage.waiting => line(PhosphorIconsRegular.hourglass, 'Adding $name to the family'),
      HubSetupStage.approving => line(PhosphorIconsRegular.hourglass, '$name is catching up with the family'),
      HubSetupStage.done => GroupCard(child: DoneRow(message: '$name keeps the family in sync')),
      HubSetupStage.confirm => GroupCard(
          child: ActionRow(
            title: session.words.join('  '),
            detail: 'The same words are in $name\'s log',
            action: FilledButton(
              onPressed: session.wordsMatch == false ? null : session.approve,
              child: Text('Approve $name'),
            ),
          ),
        ),
      HubSetupStage.failed => _codeEntry(context, session.error, hub: session.hub),
    };
  }

  Widget? _codeEntry(BuildContext context, String? error, {HubInfo? hub}) {
    final c = context.colors;
    final t = context.text;
    final target = hub ?? _hub;
    final den = context.watch(const {}).den;
    final hasHub = den.devices.any((d) => d.approved && !d.revoked && d.mode == DeviceMode.hub && d.id != den.deviceId);
    if (target == null || hasHub || (error == null && (target.paired || target.stage != 'waiting_for_code'))) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LabeledField(
          label: 'Setup code for ${target.name}',
          error: error,
          child: TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            style: t.body(c.ink),
            decoration: const InputDecoration(hintText: 'ABCD-EFGH'),
            onSubmitted: (_) => _start(target),
          ),
        ),
        const SizedBox(height: Sp.m),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(onPressed: () => _start(target), child: Text('Add ${target.name}')),
        ),
      ],
    );
  }
}
