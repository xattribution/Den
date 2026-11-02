import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show SyncState;
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/den_network.dart';
import '../../../platform/sync/local_hub.dart';

/// How this device syncs, in one line with an ink glyph: "Up to date", or what's wrong and what
/// to do. The demo family says it stays here.
class SyncLine extends StatelessWidget {
  const SyncLine({super.key});

  @override
  Widget build(BuildContext context) {
    final network = context.watch(const {}).network;
    if (network == null) {
      return const NoticeLine(icon: PhosphorIconsRegular.arrowsClockwise, message: 'The demo family stays on this device.');
    }
    return ListenableBuilder(
      listenable: network,
      builder: (context, _) {
        final status = network.status;
        final trouble = !network.isHub &&
            (status.state == SyncState.offline || status.state == SyncState.stopped) &&
            status.lastError != 'no hub';
        final failed = network.localHub.state == LocalHubState.failed;
        return NoticeLine(
          icon: trouble || failed ? PhosphorIconsBold.cloudSlash : PhosphorIconsRegular.arrowsClockwise,
          message: network.describe(),
        );
      },
    );
  }
}

/// Advanced → Hub and sync: how this device syncs, "Keep the family online" on computers and
/// Android, and for parents the hub address and relay to use.
class DeviceSyncSection extends StatelessWidget {
  const DeviceSyncSection({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final network = app.network;
    if (network == null) {
      return const DenSection(
        title: 'Sync',
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: Sp.s),
          child: NoticeLine(icon: PhosphorIconsRegular.arrowsClockwise, message: 'The demo family stays on this device.'),
        ),
      );
    }
    return ListenableBuilder(
      listenable: network,
      builder: (context, _) => _Live(network: network, parent: app.allows(DenAction.manageFamily)),
    );
  }
}

class _Live extends StatefulWidget {
  const _Live({required this.network, required this.parent});
  final DenNetwork network;
  final bool parent;

  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> {
  final _hub = TextEditingController();
  late final _relay = TextEditingController(text: widget.network.relay?.toString() ?? '');
  bool _switching = false;
  String? _hubError;
  String? _startError;

  DenNetwork get _net => widget.network;

  @override
  void dispose() {
    _hub.dispose();
    _relay.dispose();
    super.dispose();
  }

  Future<void> _keepOnline(bool on) async {
    setState(() {
      _switching = true;
      _startError = null;
    });
    final problem = await tryWrite(() => _net.keepOnline(on));
    if (!mounted) return;
    setState(() {
      _switching = false;
      _startError = problem ??
          (on && _net.localHub.state == LocalHubState.failed ? _net.localHub.error ?? "The hub couldn't start on this device." : null);
    });
  }

  Future<void> _addHub() async {
    final text = _hub.text.trim();
    if (DenNetwork.syncUriFor(text) == null) {
      setState(() => _hubError = "That isn't an address. Type something like 192.168.1.20.");
      return;
    }
    setState(() => _hubError = null);
    await _net.addHub(text);
    _hub.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final hubHere = _net.isHub;
    final local = _net.localHub;
    final sections = <Widget>[
      const DenSection(
        title: 'Sync',
        child: Padding(padding: EdgeInsets.symmetric(vertical: Sp.s), child: SyncLine()),
      ),
    ];
    if (LocalHub.supported && (widget.parent || hubHere)) {
      sections.add(DenSection(
        title: 'This device',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchLine(
              label: 'Keep the family online',
              detail: 'This device becomes the hub. Keep it plugged in, awake and on the home Wi-Fi.',
              value: hubHere,
              onChanged: _switching || !widget.parent ? null : _keepOnline,
              reason: widget.parent ? null : 'Only a parent can change this',
            ),
            if (_startError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Sp.m),
                child: Text(_startError!, style: t.meta(c.destructive)),
              ),
            if (hubHere && local.addresses.isNotEmpty) ...[
              const RowRule(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Sp.m),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Hub address', style: t.meta(c.ink2)),
                    for (final a in local.addresses) SelectableText('${a.host}:${a.port}', style: t.rowTitle(c.ink)),
                  ],
                ),
              ),
            ],
          ],
        ),
      ));
    }
    // A browser syncs with the hub that served it, wherever it is: no addresses to manage.
    if (widget.parent && !hubHere && !Capabilities.web) {
      sections.add(DenSection(
        title: 'Where the hub is',
        carded: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_net.hubs.isNotEmpty) ...[
              GroupCard(
                child: Column(
                  children: ruled([
                    for (final h in _net.hubs)
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 56),
                        child: Row(
                          children: [
                            Icon(PhosphorIconsRegular.hardDrives, size: 22, color: c.ink),
                            const SizedBox(width: 14),
                            Expanded(child: Text('${h.host}:${h.port}', style: t.body(c.ink))),
                            TextButton(
                              onPressed: () => _net.removeHub(h),
                              style: TextButton.styleFrom(foregroundColor: c.destructive),
                              child: const Text('Forget'),
                            ),
                          ],
                        ),
                      ),
                  ], indent: 36),
                ),
              ),
              const SizedBox(height: Sp.l),
            ],
            LabeledField(
              label: 'Hub address',
              error: _hubError,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _hub,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      style: t.body(c.ink),
                      decoration: const InputDecoration(hintText: '192.168.1.20'),
                      onSubmitted: (_) => _addHub(),
                    ),
                  ),
                  const SizedBox(width: Sp.s),
                  OutlinedButton(onPressed: _addHub, child: const Text('Add')),
                ],
              ),
            ),
            const SizedBox(height: Sp.l),
            LabeledField(
              label: 'Relay, for when this device is away from home',
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _relay,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      style: t.body(c.ink),
                      decoration: const InputDecoration(hintText: 'https://relay.den.family'),
                      onSubmitted: (v) => _net.setRelay(v),
                    ),
                  ),
                  const SizedBox(width: Sp.s),
                  OutlinedButton(onPressed: () => _net.setRelay(_relay.text), child: const Text('Save')),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.s, DenLayout.headingInset, 0),
              child: Text('A relay only ever sees encrypted data.', style: t.meta(c.ink2)),
            ),
          ],
        ),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, s) in sections.indexed) ...[if (i > 0) const SizedBox(height: DenLayout.sectionGap), s],
      ],
    );
  }
}
