import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show SyncState;
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/den_network.dart';
import '../../../platform/sync/local_hub.dart';
import '../../../app/app_state.dart';
import '../../../platform/capabilities.dart';

/// Settings, This device: how it syncs right now, "Keep the family online" on computers and
/// Android, and for parents the hub address and relay to use.
class DeviceSyncSection extends StatelessWidget {
  const DeviceSyncSection({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final network = app.network;
    final c = context.colors;
    if (network == null) {
      return ListTile(
        leading: Icon(PhosphorIconsRegular.arrowsClockwise, color: c.ink2),
        title: const Text('Sync'),
        subtitle: const Text('The demo family stays on this device.'),
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

  DenNetwork get _net => widget.network;

  @override
  void dispose() {
    _hub.dispose();
    _relay.dispose();
    super.dispose();
  }

  Future<void> _keepOnline(bool on) async {
    setState(() => _switching = true);
    final ok = await attempt(context, () => _net.keepOnline(on));
    if (!mounted) return;
    setState(() => _switching = false);
    if (ok && on && _net.localHub.state == LocalHubState.failed) {
      showNote(context, _net.localHub.error ?? "The hub couldn't start on this device.");
    }
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
    final hubHere = _net.isHub;
    final local = _net.localHub;
    final offline = _net.status.state == SyncState.offline || _net.status.state == SyncState.stopped;
    final unreachable = !hubHere && offline && _net.status.lastError != 'no hub';
    Widget block(Widget child, {double top = Sp.m}) =>
        Padding(padding: EdgeInsets.fromLTRB(Sp.l, top, Sp.l, 0), child: child);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(
            hubHere ? PhosphorIconsRegular.hardDrives : PhosphorIconsRegular.arrowsClockwise,
            color: unreachable || local.state == LocalHubState.failed ? c.caution : c.ink2,
          ),
          title: const Text('Sync'),
          subtitle: Text(
            _net.describe(),
            style: unreachable || local.state == LocalHubState.failed ? context.type.meta(c.caution) : null,
          ),
        ),
        if (LocalHub.supported && (widget.parent || hubHere)) ...[
          SwitchListTile(
            title: const Row(
              children: [
                Flexible(child: Text('Keep the family online')),
                InfoTip(
                  "This device becomes the family's hub: other devices sync through it, and Home Assistant "
                  'and AI connections reach it. Keep it plugged in, awake and on the home Wi-Fi.',
                ),
              ],
            ),
            value: hubHere,
            onChanged: _switching || !widget.parent ? null : _keepOnline,
          ),
          if (hubHere && local.addresses.isNotEmpty)
            block(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Hub address', style: context.type.meta(c.ink2)),
                  for (final a in local.addresses)
                    SelectableText('${a.host}:${a.port}', style: context.type.title(c.ink)),
                ],
              ),
              top: 0,
            ),
        ],
        // A browser syncs with the hub that served it, wherever it is: no addresses to manage.
        if (widget.parent && !hubHere && !Capabilities.web) ...[
          block(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _hub,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: 'Hub address',
                      hintText: '192.168.1.20',
                      errorText: _hubError,
                    ),
                    onSubmitted: (_) => _addHub(),
                  ),
                ),
                const SizedBox(width: Sp.s),
                SizedBox(height: Targets.adult, child: OutlinedButton(onPressed: _addHub, child: const Text('Add hub'))),
              ],
            ),
          ),
          for (final h in _net.hubs)
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.xs, 0),
              child: Row(
                children: [
                  Icon(PhosphorIconsRegular.hardDrives, size: 18, color: c.ink2),
                  const SizedBox(width: Sp.s),
                  Expanded(child: Text('${h.host}:${h.port}', style: context.type.body(c.ink))),
                  IconButton(
                    tooltip: 'Forget ${h.host}',
                    onPressed: () => _net.removeHub(h),
                    icon: Icon(PhosphorIconsRegular.x, size: 18, color: c.ink2),
                  ),
                ],
              ),
            ),
          block(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _relay,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Relay',
                      hintText: 'https://relay.den.family',
                      suffixIcon: InfoTip('Reaches the hub when this device is away from home. It only ever sees encrypted data.'),
                      suffixIconConstraints: BoxConstraints(minWidth: 40, minHeight: 40),
                    ),
                    onSubmitted: (v) => _net.setRelay(v),
                  ),
                ),
                const SizedBox(width: Sp.s),
                SizedBox(
                  height: Targets.adult,
                  child: OutlinedButton(onPressed: () => _net.setRelay(_relay.text), child: const Text('Save relay')),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
