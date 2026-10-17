import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/parts/family_frame.dart';
import '../../design/parts/family_words.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import 'scope_picker.dart';

/// AI and automations: requests waiting for a parent, then every connection with what it may
/// do and whose permissions it uses. Tokens are created here and shown once.
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final parent = app.allows(DenAction.manageFamily);
    final all = parent ? app.den.connections : const <Connection>[];
    final pending = all.where((x) => x.status == ConnectionStatus.pending).toList();
    final active = all.where((x) => x.status == ConnectionStatus.active).toList();
    final revoked = all.where((x) => x.status == ConnectionStatus.revoked).toList();

    return Scaffold(
      appBar: pageBar(context, 'AI and automations', maxWidth: 720),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.only(bottom: Sp.xxxl),
              children: [
                if (!parent) const EmptyLine(message: 'Only parents can manage AI and automations.'),
                for (final x in pending) _Request(x),
                if (parent) ...[
                  SectionHeader(
                    'Connected',
                    action: TextButton.icon(
                      onPressed: () => context.push('/settings/connections/new'),
                      icon: const Icon(PhosphorIconsBold.plus, size: 16),
                      label: const Text('Create token'),
                    ),
                  ),
                  if (active.isEmpty) const EmptyLine(message: 'Nothing is connected yet.'),
                  for (final x in active) _ConnectionRow(x),
                ],
                if (revoked.isNotEmpty) ...[const SectionHeader('Revoked'), for (final x in revoked) _ConnectionRow(x)],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Acts as Mia", or "Parent-level" when the connection uses no one person's permissions.
String actsAs(BuildContext context, String? memberId) {
  if (memberId == null) return 'Parent-level';
  return 'Acts as ${context.den.member(memberId)?.name ?? 'a removed person'}';
}

class _Request extends StatelessWidget {
  const _Request(this.connection);
  final Connection connection;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final x = connection;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.rule)),
      ),
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.l, Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AttentionLine(
            message:
                '${x.label} wants: ${[for (final s in Scope.values)
                  if (x.scopes.contains(s)) FamilyWords.scope(s)].join(', ')}',
          ),
          if (x.client != null)
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text(x.client!, style: context.type.meta(c.ink2)),
            ),
          const SizedBox(height: Sp.m),
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              FilledButton(onPressed: () => _approve(context), child: Text('Approve ${x.label}')),
              OutlinedButton(
                onPressed: () => attempt(context, () => context.den.revokeConnection(x.id)),
                child: const Text('Decline'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _approve(BuildContext context) async {
    final result = await showModalBottomSheet<(Set<Scope>, String?)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ApproveSheet(connection),
    );
    if (result == null || !context.mounted) return;
    await attempt(context, () => context.den.approveConnection(connection.id, scopes: result.$1, member: result.$2));
  }
}

/// Approving a request: keep or narrow what it asked for, and choose whose permissions it uses.
class _ApproveSheet extends StatefulWidget {
  const _ApproveSheet(this.connection);
  final Connection connection;

  @override
  State<_ApproveSheet> createState() => _ApproveSheetState();
}

class _ApproveSheetState extends State<_ApproveSheet> {
  late Set<Scope> _scopes = {...widget.connection.scopes};
  String? _member;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final x = widget.connection;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: Sp.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.s),
              child: Text('Approve ${x.label}', style: context.type.title(c.ink)),
            ),
            ScopePicker(value: _scopes, allowed: x.scopes, onChanged: (s) => setState(() => _scopes = s)),
            ActsAsPicker(value: _member, onChanged: (m) => setState(() => _member = m)),
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xl, Sp.l, 0),
              child: FilledButton(
                onPressed: _scopes.isEmpty ? null : () => Navigator.of(context).pop((_scopes, _member)),
                child: Text('Approve ${x.label}'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow(this.connection);
  final Connection connection;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final x = connection;
    final revoked = x.status == ConnectionStatus.revoked;
    final expires = x.expires;
    final status = revoked
        ? 'Revoked'
        : expires == null
        ? null
        : 'Expires ${DateFormat.MMMd().format(context.app.formats.at(expires))}';
    return ListTile(
      leading: Icon(
        x.kind == ConnectionKind.oauth ? PhosphorIconsRegular.robot : PhosphorIconsRegular.key,
        color: revoked ? c.ink3 : c.ink2,
      ),
      title: Text(x.label, style: context.type.body(revoked ? c.ink2 : c.ink)),
      subtitle: Text([FamilyWords.scopes(x.scopes), actsAs(context, x.member), ?status].join(' · ')),
      trailing: revoked
          ? null
          : TextButton(
              style: TextButton.styleFrom(foregroundColor: c.bad),
              onPressed: () => _revoke(context),
              child: const Text('Revoke'),
            ),
    );
  }

  Future<void> _revoke(BuildContext context) async {
    final c = context.colors;
    final x = connection;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Revoke ${x.label}?'),
        content: const Text('It stops working right away. To connect again it needs a new token or approval.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.bad, foregroundColor: c.paper),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text('Revoke ${x.label}'),
          ),
        ],
      ),
    );
    if (yes == true && context.mounted) await attempt(context, () => context.den.revokeConnection(x.id));
  }
}
