import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/hub_client.dart';
import '../../../platform/sync/hub_connections.dart';
import '../../family/family.dart';
import '../state/connection_actions.dart';
import '../widgets/hub_apps_section.dart';
import '../widgets/scope_picker.dart';

/// Advanced → AI and automations: assistants signing in to the hub, each let in by the code its
/// screen shows and then approved with what it may do and as whom; everything connected, each
/// with Remove; how to connect an assistant; tokens; the apps a parent set up for assistants
/// that can't register themselves (Alexa+); and who reads photos and messages.
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key, this.signIns, this.apps});

  /// The hub's waiting sign-ins, for tests; by default asked of the family's hub.
  final HubConnections? signIns;

  /// The hub's apps a parent set up, for tests.
  final HubAppsSource? apps;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.connection});
    final parent = app.allows(DenAction.manageFamily);
    // Letting an app in and approving it are trust decisions: a parent's own device only.
    final trusted = app.allowsTrust(DenAction.manageFamily);
    if (!parent) {
      return const DenPage(title: 'AI and automations', children: [EmptyState(message: 'Only parents can manage AI and automations.')]);
    }
    final all = app.den.connections;
    final pending = all.where((x) => x.status == ConnectionStatus.pending).toList();
    final active = all.where((x) => x.status == ConnectionStatus.active).toList();
    return DenPage(
      title: 'AI and automations',
      children: [
        if (!trusted)
          const NoticeLine(
            icon: PhosphorIconsRegular.lockKey,
            message: "Assistants are let in and removed only on a parent's own phone.",
          ),
        if (trusted) Ungapped(_Waiting(signIns: signIns, pending: pending)),
        DenSection(
          title: 'Connected',
          trailing: active.isEmpty ? null : SectionCount('${active.length}'),
          child: active.isEmpty
              ? const EmptyState(compact: true, message: 'Nothing is connected yet.')
              : Column(children: ruled([for (final x in active) _ConnectionRow(x, trusted: trusted)], indent: 36)),
        ),
        DenSection(
          title: 'Connect',
          child: Column(
            children: ruled([
              NavRow(
                icon: PhosphorIconsRegular.chatCircleText,
                label: 'Connect an assistant',
                detail: 'Claude, ChatGPT, Gemini, Grok, Siri and Alexa+',
                onTap: () => context.push('/settings/connections/guide'),
              ),
              NavRow(
                icon: PhosphorIconsRegular.key,
                label: 'Make a token',
                detail: 'For Home Assistant, a script or a Shortcut',
                onTap: trusted ? () => context.push('/settings/connections/new') : null,
              ),
              NavRow(
                icon: PhosphorIconsRegular.image,
                label: 'Reading photos and messages',
                detail: 'Who reads what you add from a photo or a message',
                onTap: () => context.push('/settings/connections/reader'),
              ),
            ], indent: 36),
          ),
        ),
        if (trusted) HubAppsSection(source: apps),
      ],
    );
  }
}

/// What waits for a parent: apps signing in to the hub (let in by the code their screen shows),
/// then requests to approve. Nothing waiting, nothing drawn.
class _Waiting extends StatefulWidget {
  const _Waiting({required this.signIns, required this.pending});

  final HubConnections? signIns;
  final List<Connection> pending;

  @override
  State<_Waiting> createState() => _WaitingState();
}

class _WaitingState extends State<_Waiting> {
  HubConnections? _client;
  List<ConnectionRequest> _requests = const [];
  final Set<String> _busy = {};
  final Map<String, String> _done = {};
  final Map<String, String> _failed = {};
  Timer? _poll;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final network = context.watch(const {}).network;
    final hasHub = network != null && (network.isHub || network.hubDevice != null);
    _client = widget.signIns ?? (hasHub ? HubConnections(network) : null);
    if (_client == null) return;
    unawaited(_load());
    // Someone signing in on another screen is waiting; look again every few seconds.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_load()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final client = _client;
    if (client == null) return;
    try {
      final all = await client.requests();
      if (mounted) setState(() => _requests = [for (final r in all) if (r.connection == null) r]);
    } on HubException catch (e) {
      // An older hub has no such list; one that can't be reached is tried again shortly.
      if (e.code == 'not_found') _poll?.cancel();
    }
  }

  Future<void> _decide(ConnectionRequest r, {required bool admit}) async {
    setState(() {
      _busy.add(r.id);
      _failed.remove(r.id);
    });
    try {
      if (admit) {
        await _client!.admit(r);
      } else {
        await _client!.decline(r);
      }
      if (!mounted) return;
      setState(() => _done[r.id] = admit
          ? '${r.clientName} is in. Approve it below once it shows up.'
          : '${r.clientName} was turned away.');
    } on HubException catch (e) {
      if (mounted) setState(() => _failed[r.id] = e.message);
    } finally {
      if (mounted) setState(() => _busy.remove(r.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final rows = <Widget>[
      for (final r in _requests)
        if (_done[r.id] != null)
          DoneRow(message: _done[r.id]!)
        else
          _signIn(context, r),
      for (final x in widget.pending) _request(context, x),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: DenLayout.sectionGap),
      child: GroupCard(
        padding: const EdgeInsets.fromLTRB(DenLayout.cardPadding, Sp.l, DenLayout.cardPadding, Sp.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(header: true, child: Text('Needs you', style: context.text.section(c.ink).withWeight(FontWeight.w800))),
            ...ruled(rows),
          ],
        ),
      ),
    );
  }

  Widget _signIn(BuildContext context, ConnectionRequest r) {
    final c = context.colors;
    final t = context.text;
    final busy = _busy.contains(r.id);
    final failed = _failed[r.id];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            r.redirectHost.isEmpty ? '${r.clientName} wants to connect' : '${r.clientName} (${r.redirectHost}) wants to connect',
            style: t.rowTitle(c.ink),
          ),
          const SizedBox(height: 2),
          Text('Let it in only if its screen shows this code', style: t.meta(c.ink2)),
          const SizedBox(height: Sp.s),
          Text('Code ${r.code}', style: t.section(c.ink)),
          const SizedBox(height: Sp.m),
          TwoButtons(
            primary: 'Let ${r.clientName} in',
            onPrimary: busy ? null : () => _decide(r, admit: true),
            secondary: 'Turn away',
            onSecondary: busy ? null : () => _decide(r, admit: false),
          ),
          if (failed != null) ...[const SizedBox(height: Sp.s), Text(failed, style: t.meta(c.destructive))],
        ],
      ),
    );
  }

  Widget _request(BuildContext context, Connection x) {
    final c = context.colors;
    return ActionRow(
      leading: SizedBox.square(dimension: 40, child: Icon(PhosphorIconsRegular.plugsConnected, size: 26, color: c.ink)),
      title: '${x.label} wants to connect',
      detail: [
        'Asks for ${FamilyWords.scopes(x.scopes).toLowerCase()}',
        ?x.client,
      ].join('. '),
      action: FilledButton(
        onPressed: () => _approve(context, x),
        child: Text('Approve ${x.label}', maxLines: 1, softWrap: false),
      ),
    );
  }

  Future<void> _approve(BuildContext context, Connection x) async {
    final result = await showDenSheet<_Who>(context, builder: (_) => _ApproveSheet(x));
    if (result == null || !context.mounted) return;
    await attempt(
      context,
      () => context.connectionActions.approve(x.id, scopes: result.scopes!, member: result.member, tz: result.tz),
    );
  }
}

/// What a parent chose for a connection: what it may do, who it acts as, where they live.
typedef _Who = ({Set<Scope>? scopes, String member, String? tz});

/// Approving a request: keep or narrow what it asked for, choose who it acts as (the parent
/// approving, unless they pick someone), and where that person lives.
class _ApproveSheet extends StatefulWidget {
  const _ApproveSheet(this.connection);
  final Connection connection;

  @override
  State<_ApproveSheet> createState() => _ApproveSheetState();
}

class _ApproveSheetState extends State<_ApproveSheet> {
  late Set<Scope> _scopes = {...widget.connection.scopes};
  late String? _member = DenScope.read(context).me?.id;
  String? _tz;

  @override
  Widget build(BuildContext context) {
    final x = widget.connection;
    final member = _member;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: 'Approve ${x.label}'),
          ScopePicker(value: _scopes, allowed: x.scopes, onChanged: (s) => setState(() => _scopes = s)),
          const SizedBox(height: DenLayout.sectionGap),
          ActsAsPicker(value: member ?? '', onChanged: (m) => setState(() => _member = m)),
          const SizedBox(height: DenLayout.sectionGap),
          ConnectionZonePicker(value: _tz, onChanged: (z) => setState(() => _tz = z)),
          const SizedBox(height: DenLayout.sectionGap),
          FilledButton(
            onPressed: _scopes.isEmpty || member == null
                ? null
                : () => Navigator.of(context).pop((scopes: _scopes, member: member, tz: _tz)),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: Text('Approve ${x.label}'),
          ),
        ],
      ),
    );
  }
}

/// Changing who an approved connection acts as, and where they live.
class _ChangeSheet extends StatefulWidget {
  const _ChangeSheet(this.connection, this.member);
  final Connection connection;
  final String? member;

  @override
  State<_ChangeSheet> createState() => _ChangeSheetState();
}

class _ChangeSheetState extends State<_ChangeSheet> {
  late String? _member = widget.member ?? DenScope.read(context).me?.id;
  late String? _tz = widget.connection.tz;

  @override
  Widget build(BuildContext context) {
    final x = widget.connection;
    final member = _member;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: x.label),
          ActsAsPicker(value: member ?? '', onChanged: (m) => setState(() => _member = m)),
          const SizedBox(height: DenLayout.sectionGap),
          ConnectionZonePicker(value: _tz, onChanged: (z) => setState(() => _tz = z)),
          const SizedBox(height: DenLayout.sectionGap),
          FilledButton(
            onPressed: member == null ? null : () => Navigator.of(context).pop((scopes: null, member: member, tz: _tz)),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/// "As Mia": who a connection acts as. One approved before every connection acted as someone
/// acts as the parent who approved it; stopped when that parent left or is no longer a parent,
/// until a parent taps Change and chooses who it acts as.
String actsAs(BuildContext context, Connection connection) {
  final den = DenScope.read(context).den;
  final id = den.connectionActsAs(connection);
  if (id == null) return 'Stopped: tap Change to choose who it acts as';
  return 'As ${den.member(id)?.name ?? 'a removed person'}';
}

/// One connection: what it is, what it may do and as whom, and Remove, said in place first.
class _ConnectionRow extends StatefulWidget {
  const _ConnectionRow(this.connection, {required this.trusted});
  final Connection connection;
  final bool trusted;

  @override
  State<_ConnectionRow> createState() => _ConnectionRowState();
}

class _ConnectionRowState extends State<_ConnectionRow> {
  bool _removing = false;
  bool _busy = false;
  String? _error;

  Future<void> _remove() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await tryWrite(() => context.connectionActions.revoke(widget.connection.id));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
    });
  }

  Future<void> _change() async {
    final x = widget.connection;
    final member = DenScope.read(context).den.connectionActsAs(x);
    final result = await showDenSheet<_Who>(context, builder: (_) => _ChangeSheet(x, member));
    if (result == null || !mounted) return;
    await attempt(context, () => context.connectionActions.update(x.id, member: result.member, tz: result.tz));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final x = widget.connection;
    final expires = x.expires;
    final zone = x.tz;
    final detail = [
      FamilyWords.scopes(x.scopes),
      actsAs(context, x),
      if (zone != null) zone.split('/').last.replaceAll('_', ' '),
      if (expires != null) 'Until ${DateFormat.MMMd().format(context.watch(const {}).formats.at(expires))}',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              Icon(x.kind == ConnectionKind.oauth ? PhosphorIconsRegular.chatCircleText : PhosphorIconsRegular.key, size: 22, color: c.ink),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.s),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [Text(x.label, style: t.body(c.ink)), Text(detail, style: t.meta(c.ink2))],
                  ),
                ),
              ),
              if (widget.trusted && !_removing) ...[
                TextButton(onPressed: _change, child: const Text('Change')),
                TextButton(
                  onPressed: () => setState(() => _removing = true),
                  style: TextButton.styleFrom(foregroundColor: c.destructive),
                  child: const Text('Remove'),
                ),
              ],
            ],
          ),
        ),
        DenReveal(
          visible: _removing,
          child: !_removing
              ? const SizedBox(width: double.infinity)
              : ConfirmPanel(
                  message: '${x.label} stops working right away. To connect again it needs a new token or approval.',
                  confirmLabel: 'Remove ${x.label}',
                  destructive: true,
                  busy: _busy,
                  error: _error,
                  onConfirm: _remove,
                  onCancel: () => setState(() => _removing = false),
                ),
        ),
      ],
    );
  }
}
