import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/forms/frame.dart';
import '../../../design/pickers/family_pickers.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/hub_client.dart';
import '../../../platform/sync/pairing.dart';
import '../../../app/app_state.dart';

/// Adding a hub (a NAS, a Raspberry Pi, an always-on computer): find it on the network or type
/// its address, enter the setup code it printed, then compare the words and approve it.
class AddHubScreen extends StatefulWidget {
  const AddHubScreen({super.key, this.session});

  /// Shows a setup already under way, for tests.
  final HubSetupSession? session;

  @override
  State<AddHubScreen> createState() => _AddHubScreenState();
}

class _AddHubScreenState extends State<AddHubScreen> {
  final _address = TextEditingController();
  final _code = TextEditingController();
  List<FoundHub>? _found;
  bool _busy = false;
  String? _error;
  HubInfo? _ours;
  late HubSetupSession? _session = widget.session;
  PairingService? _pairing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pairing = Pairing.of(context);
    if (pairing != _pairing) {
      _pairing = pairing;
      if (widget.session == null) _look();
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    _session?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _look() async {
    setState(() => _found = null);
    final found = await _pairing!.findHubs();
    if (mounted) setState(() => _found = found);
  }

  Future<void> _add() async {
    final address = _address.text.trim();
    final code = _code.text.trim();
    setState(() {
      _error = null;
      _ours = null;
    });
    if (address.isEmpty) {
      setState(() => _error = "Type the hub's address, or pick it from the hubs on this network.");
      return;
    }
    setState(() => _busy = true);
    try {
      final info = await _pairing!.hubStatus(address);
      if (!mounted) return;
      if (info.paired) {
        setState(() {
          if (isFamilyHub(context.den, info.device)) {
            _ours = info;
          } else {
            _error = '${info.name} already belongs to another family. Reset its data to start over, then try again.';
          }
        });
        return;
      }
      if (code.replaceAll(RegExp(r'[\s-]'), '').length != 8) {
        setState(() => _error = 'Enter the 8-character setup code from ${info.name}.');
        return;
      }
      final session = _pairing!.setUpHub(info, code);
      session.addListener(_changed);
      setState(() => _session = session);
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useOurs() async {
    final info = _ours!;
    await _pairing!.useHub(info);
    if (mounted) showNote(context, 'This device syncs with ${info.name} now.');
    if (mounted) context.pop();
  }

  void _startOver() {
    _session?.removeListener(_changed);
    setState(() {
      _session = null;
      _code.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session != null) return _Progress(session: session, onStartOver: _startOver);
    final c = context.colors;
    final found = _found;

    return FormFrame(
      title: 'Add a hub',
      bottom: SizedBox(
        width: double.infinity,
        child: FilledButton(onPressed: _busy ? null : _add, child: Text(_busy ? 'Checking the hub' : 'Add this hub')),
      ),
      children: [
        SectionHeader(
          'On this network',
          action: TextButton(onPressed: found == null ? null : _look, child: const Text('Look again')),
        ),
        if (found == null)
          FormBlock(top: 0, child: Text('Looking for hubs', style: context.type.body(c.ink2)))
        else if (found.isEmpty)
          FormBlock(top: 0, child: Text('No hubs answered on this network.', style: context.type.body(c.ink2)))
        else
          for (final hub in found)
            ListTile(
              leading: Icon(PhosphorIconsRegular.hardDrives, color: c.ink2),
              title: Text(hub.name),
              subtitle: Text([
                hub.address,
                if (hub.familyId != null && hub.familyId == context.den.familyId) 'In your family',
                if (hub.familyId != null && hub.familyId != context.den.familyId) 'In another family',
                if (hub.familyId == null) 'Waiting for setup',
              ].join(' · ')),
              trailing: _address.text == hub.address ? Icon(PhosphorIconsBold.check, color: c.ink) : null,
              onTap: () => setState(() => _address.text = hub.address),
            ),
        FormBlock(
          top: Sp.xl,
          child: TextField(
            controller: _address,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Hub address', hintText: '192.168.1.20'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const FormBlock(
          child: FieldLabel(
            'Setup code',
            info: "A new hub prints an 8-character code like ABCD-EFGH. Find it in the hub's log, by running "
                '"den_hub setup-code" on it, or on the hub\'s web page.',
          ),
        ),
        FormBlock(
          top: 0,
          child: TextField(
            controller: _code,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            maxLength: 9,
            style: context.type.title(c.ink).copyWith(letterSpacing: 2),
            decoration: const InputDecoration(hintText: 'ABCD-EFGH', counterText: ''),
            onSubmitted: (_) => _add(),
          ),
        ),
        if (_error != null) FormBlock(child: AttentionLine(message: _error!, bad: true)),
        if (_ours != null)
          FormBlock(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AttentionLine(message: '${_ours!.name} is already in your family.'),
                const SizedBox(height: Sp.s),
                OutlinedButton(onPressed: _useOurs, child: Text('Sync with ${_ours!.name}')),
              ],
            ),
          ),
      ],
    );
  }
}

/// How the hub's own words compare with this phone's: the same, different (someone may be in
/// the middle, so approving is off), or not reported (compare with the hub's log by eye).
class _WordsCheck extends StatelessWidget {
  const _WordsCheck({required this.name, required this.matches, required this.hubWords});
  final String name;
  final bool? matches;
  final List<String> hubWords;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return switch (matches) {
      true => Row(
          children: [
            Icon(PhosphorIconsBold.check, size: 18, color: c.ink),
            const SizedBox(width: Sp.s),
            Expanded(child: Text('$name shows the same three words.', style: context.type.body(c.ink))),
          ],
        ),
      false => AttentionLine(
          bad: true,
          message: '$name shows different words: ${hubWords.join(' ')}. Something between this phone and the hub '
              'may be listening in. Decline, then add the hub again.',
        ),
      null => Text(
          "$name didn't report its words. Compare them with the ones in its log before you approve.",
          style: context.type.body(c.ink2),
        ),
    };
  }
}

/// The setup after the code went out: waiting for the hub, the words and Approve, then done.
class _Progress extends StatelessWidget {
  const _Progress({required this.session, required this.onStartOver});
  final HubSetupSession session;
  final VoidCallback onStartOver;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final name = session.hub.name;
    Widget line(IconData icon, String text) => Row(
          children: [
            Icon(icon, size: 20, color: c.ink2),
            const SizedBox(width: Sp.m),
            Expanded(child: Text(text, style: context.type.body(c.ink2))),
          ],
        );

    return FormFrame(
      title: 'Add a hub',
      bottom: switch (session.stage) {
        HubSetupStage.done => SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: () => context.pop(), child: const Text('Done')),
          ),
        HubSetupStage.failed => SizedBox(
            width: double.infinity,
            child: OutlinedButton(onPressed: onStartOver, child: const Text('Try again')),
          ),
        _ => null,
      },
      children: [
        ListTile(
          leading: Icon(PhosphorIconsRegular.hardDrives, color: c.ink2),
          title: Text(name),
          subtitle: Text(session.hub.address),
        ),
        FormBlock(
          child: switch (session.stage) {
            HubSetupStage.sending => line(PhosphorIconsRegular.hourglass, 'Sending the setup code to $name'),
            HubSetupStage.waiting => line(PhosphorIconsRegular.hourglass, 'Waiting for $name to ask to join'),
            HubSetupStage.confirm => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AttentionLine(message: '$name wants to join'),
                  const SizedBox(height: Sp.s),
                  Row(
                    children: [
                      Text('Words', style: context.type.meta(c.ink2)),
                      InfoTip(
                        'Three words from the connection to $name. The hub works out the same three on its '
                        'side, reports them here, and prints them in its log ("den_hub status" shows them too). '
                        'Approve only if they match.',
                      ),
                    ],
                  ),
                  const SizedBox(height: Sp.xs),
                  Text(session.words.join('  '), style: context.type.heading(c.ink)),
                  const SizedBox(height: Sp.s),
                  _WordsCheck(name: name, matches: session.wordsMatch, hubWords: session.hubWords),
                  const SizedBox(height: Sp.l),
                  Wrap(
                    spacing: Sp.s,
                    runSpacing: Sp.s,
                    children: [
                      FilledButton(
                        onPressed: session.wordsMatch == false ? null : session.approve,
                        child: Text('Approve $name'),
                      ),
                      OutlinedButton(
                        onPressed: () async {
                          await session.cancel();
                          if (context.mounted) context.pop();
                        },
                        child: const Text('Decline'),
                      ),
                    ],
                  ),
                ],
              ),
            HubSetupStage.approving => line(PhosphorIconsRegular.arrowsClockwise, '$name is catching up with the family'),
            HubSetupStage.done => Row(
                children: [
                  Icon(PhosphorIconsBold.check, size: 20, color: c.ink),
                  const SizedBox(width: Sp.m),
                  Expanded(child: Text('$name is in the family. Devices sync through it now.', style: context.type.body(c.ink))),
                ],
              ),
            HubSetupStage.failed => AttentionLine(message: session.error ?? "Adding $name didn't finish. Try again.", bad: true),
          },
        ),
      ],
    );
  }
}

