import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/hub_client.dart';
import '../../../platform/sync/pairing.dart';
import '../../../app/app_state.dart';
import '../../family/family.dart';

/// Adding a hub (a NAS, a Raspberry Pi, an always-on computer): find it on the network or type
/// its address, enter the setup code it printed, then compare the words and approve it. When an
/// older hub of the family used the same address (the hub was reset), the last step offers to
/// remove that one too.
class AddHubScreen extends StatefulWidget {
  const AddHubScreen({super.key, this.session, this.replaces = const []});

  /// Shows a setup already under way, for tests.
  final HubSetupSession? session;

  /// The family's hubs at the same address, with [session], for tests.
  final List<Device> replaces;

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
  late List<Device> _replaces = widget.replaces;
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
      // Hubs of the family that answered at this address before (the hub there was reset):
      // found now, before the new one's address is saved.
      final replaces = context.app.network?.hubsAt(info.base, except: info.device) ?? const <Device>[];
      final session = _pairing!.setUpHub(info, code);
      session.addListener(_changed);
      setState(() {
        _session = session;
        _replaces = replaces;
      });
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
    if (session != null) return _Progress(session: session, replaces: _replaces, onStartOver: _startOver);
    final c = context.colors;
    final found = _found;

    final t = context.text;
    return DenPage(
      title: 'Add a hub',
      bottom: FilledButton(
        onPressed: _busy ? null : _add,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(_busy ? 'Checking the hub' : 'Add this hub'),
      ),
      children: [
        DenSection(
          title: 'On this network',
          trailing: found == null ? null : SectionLink('Look again', onTap: _look),
          child: found == null
              ? Padding(padding: const EdgeInsets.symmetric(vertical: Sp.l), child: Text('Looking for hubs', style: t.body(c.ink2)))
              : found.isEmpty
                  ? const EmptyState(compact: true, message: 'No hubs answered on this network.')
                  : Column(
                      children: ruled([
                        for (final hub in found)
                          NavRow(
                            leading: _address.text == hub.address
                                ? Icon(PhosphorIconsBold.check, size: 22, color: c.ink)
                                : Icon(PhosphorIconsRegular.hardDrives, size: 22, color: c.ink),
                            label: hub.name,
                            detail: [
                              hub.address,
                              if (hub.familyId != null && hub.familyId == context.den.familyId) 'In your family',
                              if (hub.familyId != null && hub.familyId != context.den.familyId) 'In another family',
                              if (hub.familyId == null) 'Waiting for setup',
                            ].join(' · '),
                            chevron: false,
                            onTap: () => setState(() => _address.text = hub.address),
                          ),
                      ], indent: 36),
                    ),
        ),
        LabeledField(
          label: 'Hub address',
          child: TextField(
            controller: _address,
            autocorrect: false,
            keyboardType: TextInputType.url,
            style: t.body(c.ink),
            decoration: const InputDecoration(hintText: '192.168.1.20'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        LabeledField(
          label: "Setup code, from the hub's log or its web page",
          error: _error,
          child: TextField(
            controller: _code,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            maxLength: 9,
            style: t.rowTitle(c.ink).copyWith(letterSpacing: 2),
            decoration: const InputDecoration(hintText: 'ABCD-EFGH', counterText: ''),
            onSubmitted: (_) => _add(),
          ),
        ),
        if (_ours != null)
          GroupCard(
            child: ActionRow(
              title: '${_ours!.name} is already in your family',
              action: OutlinedButton(onPressed: _useOurs, child: Text('Sync with ${_ours!.name}')),
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
            Expanded(child: Text('$name shows the same three words.', style: context.text.body(c.ink))),
          ],
        ),
      false => AttentionLine(
          bad: true,
          message: '$name shows different words: ${hubWords.join(' ')}. Something between this phone and the hub '
              'may be listening in. Decline, then add the hub again.',
        ),
      null => Text(
          "$name didn't report its words. Compare them with the ones in its log before you approve.",
          style: context.text.body(c.ink2),
        ),
    };
  }
}

/// The setup after the code went out: waiting for the hub, the words and Approve, then done.
class _Progress extends StatelessWidget {
  const _Progress({required this.session, required this.replaces, required this.onStartOver});
  final HubSetupSession session;
  final List<Device> replaces;
  final VoidCallback onStartOver;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final name = session.hub.name;
    Widget line(IconData icon, String text) => Row(
          children: [
            Icon(icon, size: 20, color: c.ink2),
            const SizedBox(width: Sp.m),
            Expanded(child: Text(text, style: context.text.body(c.ink2))),
          ],
        );

    return DenPage(
      title: 'Add a hub',
      bottom: switch (session.stage) {
        HubSetupStage.done => FilledButton(onPressed: () => context.pop(), child: const Text('Done')),
        HubSetupStage.failed => OutlinedButton(onPressed: onStartOver, child: const Text('Try again')),
        _ => null,
      },
      children: [
        GroupCard(
          child: NavRow(icon: PhosphorIconsRegular.hardDrives, label: name, detail: session.hub.address, chevron: false, onTap: null),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: switch (session.stage) {
            HubSetupStage.sending => line(PhosphorIconsRegular.hourglass, 'Sending the setup code to $name'),
            HubSetupStage.waiting => line(PhosphorIconsRegular.hourglass, 'Waiting for $name to ask to join'),
            HubSetupStage.confirm => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AttentionLine(message: '$name wants to join'),
                  const SizedBox(height: Sp.s),
                  Text("The same three words show in the hub's log", style: context.text.meta(c.ink2)),
                  const SizedBox(height: Sp.xs),
                  Text(session.words.join('  '), style: context.text.sheetTitle(c.ink)),
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
                  Expanded(child: Text('$name is in the family. Devices sync through it now.', style: context.text.body(c.ink))),
                ],
              ),
            HubSetupStage.failed => AttentionLine(message: session.error ?? "Adding $name didn't finish. Try again.", bad: true),
          },
        ),
        if (session.stage == HubSetupStage.done && replaces.isNotEmpty && TrustActions.mayRemoveHubs(context.app.den))
          _ReplaceOffer(older: replaces),
      ],
    );
  }
}

/// After adding a hub where an older one of the family used to answer: the old one is dead (the
/// hub was reset), so offer to remove it, and the family's devices stop looking for it.
class _ReplaceOffer extends StatefulWidget {
  const _ReplaceOffer({required this.older});
  final List<Device> older;

  @override
  State<_ReplaceOffer> createState() => _ReplaceOfferState();
}

class _ReplaceOfferState extends State<_ReplaceOffer> {
  bool _busy = false;
  bool _removed = false;
  bool _kept = false;
  String? _error;

  Future<void> _remove() async {
    final trust = context.trustActions;
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await tryWrite(() async {
      for (final d in widget.older) {
        await trust.removeHub(d.id);
      }
      return null;
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
      _removed = problem == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final f = context.app.formats;
    final one = widget.older.length == 1 ? widget.older.single : null;
    final old = one == null
        ? '${widget.older.length} older hubs'
        : 'The ${one.name} added ${DateFormat.MMMd().format(f.at((one.rec.fieldTimes['approved'] ?? one.rec.updated).millis))}';
    return DenSection(
      title: one == null ? 'The old hubs' : 'The old hub',
      child: Padding(
        padding: const EdgeInsets.only(top: Sp.m),
        child: DenCrossfade(
          child: _removed
              ? Padding(
                  key: const ValueKey('removed'),
                  padding: const EdgeInsets.only(bottom: Sp.l),
                  child: Row(
                    children: [
                      Icon(PhosphorIconsBold.check, size: 20, color: c.ink),
                      const SizedBox(width: Sp.m),
                      Expanded(
                        child: Text(one == null ? 'Removed the old hubs.' : 'Removed the old ${one.name}.', style: context.text.body(c.ink)),
                      ),
                    ],
                  ),
                )
              : _kept
                  ? Padding(
                      key: const ValueKey('kept'),
                      padding: const EdgeInsets.only(bottom: Sp.l),
                      child: Text('Kept. You can remove ${one == null ? 'them' : 'it'} later in Hub and sync.', style: context.text.body(c.ink2)),
                    )
                  : ConfirmPanel(
                      key: const ValueKey('ask'),
                      message: '$old used this address before. Now that the new one answers there, remove '
                          "${one == null ? 'them' : 'it'} so the family's devices stop looking for ${one == null ? 'them' : 'it'}.",
                      confirmLabel: one == null ? 'Remove the old hubs' : 'Remove the old hub',
                      cancelLabel: 'Keep it',
                      destructive: true,
                      busy: _busy,
                      error: _error,
                      onConfirm: _remove,
                      onCancel: () => setState(() => _kept = true),
                    ),
        ),
      ),
    );
  }
}

