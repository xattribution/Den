import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../../platform/sync/hub_client.dart' show HubException;
import '../../../platform/sync/server_setup.dart';

/// Settings → Advanced → Server, on a parent's own phone in the server's own family: how the
/// server reaches the internet (Cloudflare, and the family's address), a new tunnel token (never
/// shown again once saved), and which Den it runs, with "Update now" when the updater says a
/// newer one is out. Without an updater (a dev build) there is no update row.
class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key, this.source});

  /// The server's side; tests pass a fake.
  final ServerSource? source;

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  ServerSource? _source;
  bool _started = false;
  bool _loading = true;
  bool _notHost = false;
  bool _busy = false;
  bool _changing = false;
  ServerState? _state;
  String? _error;
  final _token = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final network = context.watch(const {}).network;
    final hasHub = network != null && (network.isHub || network.hubDevice != null);
    _source = widget.source ?? (hasHub ? HubServerSource(network) : null);
    _load();
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final source = _source;
    if (source == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final s = await source.server();
      if (mounted) setState(() => _state = s);
    } on HubException catch (e) {
      if (mounted) {
        setState(() {
          _notHost = e.code == 'host_family_only';
          _error = _notHost ? null : e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _do(Future<ServerState> Function() call, {VoidCallback? after}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await call();
      if (!mounted) return;
      setState(() => _state = s);
      after?.call();
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _saveToken() {
    if (_token.text.trim().isEmpty) {
      setState(() => _error = 'Paste the token first.');
      return;
    }
    _do(() => _source!.saveToken(_token.text), after: () {
      _token.clear();
      _changing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final t = context.text;
    final own = app.allowsTrust(DenAction.manageFamily) && app.den.thisDevice?.mode == DeviceMode.personal;
    final s = _state;
    final net = s?.internet;
    final update = s?.update;
    return DenPage(
      title: 'Server',
      children: [
        if (!own)
          const NoticeLine(icon: PhosphorIconsRegular.lockKey, message: 'This is changed on a parent\'s own phone.')
        else if (_source == null)
          const NoticeLine(icon: PhosphorIconsRegular.info, message: 'This needs the family\'s server.')
        else if (_loading && s == null)
          const NoticeLine(icon: PhosphorIconsRegular.hourglass, message: 'Asking the server')
        else if (_notHost)
          const NoticeLine(icon: PhosphorIconsRegular.lockKey, message: 'Whoever runs your family\'s server looks after it.')
        else if (s == null)
          GroupCard(child: ErrorState(message: _error ?? 'Couldn\'t reach the server.', actionLabel: 'Try again', onAction: _load))
        else ...[
          if (net!.available)
            DenSection(
              title: 'The internet',
              child: Column(
                children: ruled([
                  InfoRow.text(
                    label: 'Cloudflare',
                    value: net.connected
                        ? 'Connected'
                        : net.token
                            ? 'Not connected'
                            : 'Off',
                  ),
                  if (s.address != null) InfoRow.text(label: 'Address', value: Uri.parse(s.address!).host),
                  NavRow(
                    icon: PhosphorIconsRegular.key,
                    label: net.token ? 'Change the tunnel token' : 'Add a tunnel token',
                    onTap: _busy ? null : () => setState(() => _changing = !_changing),
                  ),
                ], indent: 36),
              ),
            ),
          if (net.problem != null) Text(tidy(net.problem!), style: t.body(c.destructive)),
          if (_changing) ...[
            LabeledField(
              label: 'New tunnel token',
              child: TextField(
                controller: _token,
                minLines: 2,
                maxLines: 4,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                style: t.body(c.ink),
                decoration: const InputDecoration(hintText: 'eyJhIjoi…'),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(onPressed: _busy ? null : _saveToken, child: Text(_busy ? 'Saving' : 'Save token')),
            ),
          ],
          DenSection(
            title: 'Den on the server',
            child: Column(
              children: ruled([
                InfoRow.text(label: 'Version', value: s.version),
              ]),
            ),
          ),
          if (update != null && update.state == 'updating')
            const NoticeLine(icon: PhosphorIconsBold.arrowsClockwise, message: 'Updating. Den restarts in a minute or two.')
          else if (update != null && update.available != null) ...[
            Text('Update available: ${update.available}', style: t.rowTitle(c.ink)),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _busy ? null : () => _do(_source!.updateNow),
                child: const Text('Update now'),
              ),
            ),
          ],
          if (update != null && update.state == 'failed' && update.message != null)
            Text(tidy(update.message!), style: t.meta(c.ink2)),
          if (_error != null) Text(tidy(_error!), style: t.body(c.destructive)),
        ],
      ],
    );
  }
}
