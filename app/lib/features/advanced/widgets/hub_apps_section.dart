import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/hub_client.dart';
import '../../family/family.dart';
import '../state/hub_apps.dart';

export '../state/hub_apps.dart' show HubApp, HubAppsSource;

/// Apps a parent set up on the hub for assistants that can't register themselves (Alexa+): each
/// with Remove, and "Set up an app", which shows its id and secret once. Signing in with one
/// still waits for a parent's approval like any other. Nothing when the family has no hub.
class HubAppsSection extends StatefulWidget {
  const HubAppsSection({super.key, this.source});

  final HubAppsSource? source;

  @override
  State<HubAppsSection> createState() => _HubAppsSectionState();
}

class _HubAppsSectionState extends State<HubAppsSection> {
  HubAppsSource? _source;
  List<HubApp>? _apps;
  String? _error;
  String? _removing;
  bool _busy = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final network = context.watch(const {}).network;
    final hasHub = network != null && (network.isHub || network.hubDevice != null);
    _source = widget.source ?? (hasHub ? HubApps(network) : null);
    _load();
  }

  Future<void> _load() async {
    final source = _source;
    if (source == null) return;
    try {
      final apps = await source.list();
      if (mounted) {
        setState(() {
          _apps = apps;
          _error = null;
        });
      }
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _remove(HubApp app) async {
    setState(() => _busy = true);
    try {
      await _source!.remove(app.id);
      if (!mounted) return;
      setState(() {
        _apps = [for (final a in _apps ?? const <HubApp>[]) if (a.id != app.id) a];
        _removing = null;
      });
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setUp() async {
    await showDenSheet<void>(context, builder: (_) => _SetUpSheet(source: _source!));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_source == null) return const SizedBox.shrink();
    final c = context.colors;
    final t = context.text;
    final apps = _apps;
    final Widget body;
    if (_error != null && apps == null) {
      body = ErrorState(message: _error!, actionLabel: 'Try again', onAction: _load);
    } else if (apps == null) {
      body = Padding(padding: const EdgeInsets.symmetric(vertical: Sp.l), child: Text('Asking the hub', style: t.body(c.ink2)));
    } else if (apps.isEmpty) {
      body = EmptyState(
        compact: true,
        message: 'For Alexa+, which needs an id and a secret from you.',
        actionLabel: 'Set up an app',
        onAction: _setUp,
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...ruled([
            for (final a in apps)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.name, style: t.body(c.ink)),
                              Text('Id ${a.id}', style: t.meta(c.ink2)),
                            ],
                          ),
                        ),
                        if (_removing != a.id)
                          TextButton(
                            onPressed: () => setState(() => _removing = a.id),
                            style: TextButton.styleFrom(foregroundColor: c.destructive),
                            child: const Text('Remove'),
                          ),
                      ],
                    ),
                  ),
                  DenReveal(
                    visible: _removing == a.id,
                    child: _removing != a.id
                        ? const SizedBox(width: double.infinity)
                        : ConfirmPanel(
                            message: '${a.name} can no longer sign in, and what it connected stops working.',
                            confirmLabel: 'Remove ${a.name}',
                            destructive: true,
                            busy: _busy,
                            error: _error,
                            onConfirm: () => _remove(a),
                            onCancel: () => setState(() => _removing = null),
                          ),
                  ),
                ],
              ),
          ]),
          const RowRule(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.s),
            child: Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: _setUp, child: const Text('Set up another app'))),
          ),
        ],
      );
    }
    return DenSection(title: 'Apps you set up', child: body);
  }
}

/// Setting up an app: its name and where its sign-in returns, then its id and secret, once.
class _SetUpSheet extends StatefulWidget {
  const _SetUpSheet({required this.source});
  final HubAppsSource source;

  @override
  State<_SetUpSheet> createState() => _SetUpSheetState();
}

class _SetUpSheetState extends State<_SetUpSheet> {
  final _name = TextEditingController(text: 'Alexa');
  final _redirects = TextEditingController();
  HubApp? _made;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _redirects.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final redirects = _redirects.text.split(RegExp(r'[\s,]+')).where((u) => u.isNotEmpty).toList();
    if (_name.text.trim().isEmpty || redirects.isEmpty) {
      setState(() => _error = 'Give it a name and at least one address it returns to.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final made = await widget.source.create(_name.text.trim(), redirects);
      if (mounted) setState(() => _made = made);
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final made = _made;
    Widget copyable(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.s),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text(label, style: t.meta(c.ink2)), SelectableText(value, style: t.body(c.ink))],
                ),
              ),
              TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: value)), child: const Text('Copy')),
            ],
          ),
        );
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, MediaQuery.viewInsetsOf(context).bottom + Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: made == null ? 'Set up an app' : made.name, actionLabel: made == null ? 'Close' : 'Done', primary: made != null),
          if (made == null) ...[
            LabeledField(
              label: 'Name',
              child: TextField(controller: _name, style: t.body(c.ink), textCapitalization: TextCapitalization.words),
            ),
            const SizedBox(height: Sp.l),
            LabeledField(
              label: 'Where it returns after signing in',
              error: _error,
              child: TextField(
                controller: _redirects,
                minLines: 2,
                maxLines: 4,
                autocorrect: false,
                keyboardType: TextInputType.url,
                style: t.body(c.ink),
                decoration: const InputDecoration(hintText: 'The addresses the Alexa+ Developer Hub lists, one per line'),
              ),
            ),
            const SizedBox(height: Sp.xl),
            FilledButton(onPressed: _busy ? null : _create, child: const Text('Set up the app')),
          ] else ...[
            NoticeLine(message: "Den won't show the secret again. Copy it into the Alexa+ account linking setup now."),
            const SizedBox(height: Sp.s),
            GroupCard(
              child: Column(
                children: ruled([
                  copyable('Client id', made.id),
                  if (made.secret != null) copyable('Client secret', made.secret!),
                  for (final e in made.extra.entries)
                    copyable(switch (e.key) {
                      'authorization_endpoint' => 'Sign-in address',
                      'token_endpoint' => 'Token address',
                      _ => 'Den address',
                    }, e.value),
                ]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
