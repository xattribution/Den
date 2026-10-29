import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/pictograms.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/pairing.dart';
import '../state/family_needs.dart';
import '../state/recovery.dart';
import '../state/trust_actions.dart';
import '../words/family_words.dart';
import '../words/recovery_lines.dart';
import 'family_parts.dart';
import 'person_sheets.dart';

/// Needs you at the top of Family (Family.dc.html): devices asking to join, assistants asking
/// to connect, and a parent's PIN once there's a shared screen, each with its one answer, which
/// becomes what it did with Undo in place. Nothing waiting, nothing drawn. A parent's own device
/// only: these are trust decisions.
class FamilyNeedsCard extends StatefulWidget {
  const FamilyNeedsCard({super.key, this.gap = DenLayout.sectionGap});

  /// Room under the card, when there is one.
  final double gap;

  @override
  State<FamilyNeedsCard> createState() => _FamilyNeedsCardState();
}

class _Settled {
  const _Settled(this.message, this.receipt);
  final String message;
  final Receipt? receipt;
}

class _FamilyNeedsCardState extends State<FamilyNeedsCard> {
  final _order = <String>[];
  final _seen = <String, FamilyNeed>{};
  final _settled = <String, _Settled>{};
  final _failed = <String, String>{};
  final _busy = <String>{};

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.connection});
    return StreamBuilder<List<PendingJoin>>(
      stream: Pairing.of(context).pendingJoins,
      builder: (context, snap) {
        final needs = familyNeeds(app, snap.data ?? const []);
        final live = <String, FamilyNeed>{};
        for (final n in needs) {
          live[n.key] = n;
          _seen[n.key] = n;
          if (!_order.contains(n.key)) _order.add(n.key);
        }
        final rows = <Widget>[];
        for (final key in _order) {
          final settled = _settled[key];
          final need = live[key] ?? (settled != null ? _seen[key] : null);
          if (need == null) continue;
          final receipt = settled?.receipt;
          rows.add(KeyedSubtree(
            key: ValueKey(key),
            child: DoneSwap(
              done: settled == null
                  ? null
                  : DoneRow(
                      message: settled.message,
                      onUndo: receipt != null && receipt.undoable && !_busy.contains(key) ? () => _undo(key) : null,
                    ),
              child: _ask(context, app, need),
            ),
          ));
        }
        if (rows.isEmpty) return const SizedBox.shrink();
        final c = context.colors;
        return Padding(
          padding: EdgeInsets.only(bottom: widget.gap),
          child: GroupCard(
            padding: const EdgeInsets.fromLTRB(DenLayout.cardPadding, Sp.l, DenLayout.cardPadding, Sp.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(header: true, child: Text('Needs you', style: context.text.section(c.ink).withWeight(FontWeight.w800))),
                ...ruled(rows, indent: 0),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _ask(BuildContext context, AppState app, FamilyNeed need) {
    final c = context.colors;
    final t = context.text;
    final key = need.key;
    final busy = _busy.contains(key);
    final failed = _failed[key];
    final (Widget face, String title, String detail, Widget actions) = switch (need) {
      JoinAsk(:final member, :final name, :final kind, :final words) => (
          faceOr(member, Pictograms.device(kind), context, size: 44),
          '$name wants to join',
          [
            member == null ? 'It names nobody yet: you choose whose it is' : 'From your invite to ${member.name}',
            if (words.isNotEmpty) 'Their screen shows ${words.join(' ')}',
          ].join('. '),
          TwoButtons(
            primary: member == null ? 'Let it in' : 'Let ${member.name} in',
            onPrimary: busy ? null : () => _letIn(app, need),
            secondary: member == null ? 'Turn it away' : "That's not ${member.name}",
            onSecondary: busy ? null : () => _turnAway(app, need),
          ),
        ),
      ConnectionAsk(:final connection) => (
          faceOr(null, PhosphorIconsRegular.plugsConnected, context, size: 44),
          '${connection.label} wants to connect',
          connection.member == null
              ? 'Asks for ${FamilyWords.scopes(connection.scopes).toLowerCase()}'
              : 'As ${app.memberById(connection.member)?.name ?? 'someone'}',
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () => context.push('/settings/connections'),
              child: const Text('Review', maxLines: 1, softWrap: false),
            ),
          ),
        ),
      RecoveredNotice(:final device) => (
          faceOr(app.memberById(recoveryOf(device)?.member), PhosphorIconsRegular.key, context, size: 44),
          RecoveryLines.sentence(app, device),
          RecoveryLines.detail(app, device),
          TwoButtons(
            primary: 'OK',
            onPrimary: busy ? null : () => _acknowledge(device),
            secondary: "That wasn't us",
            onSecondary: busy ? null : () => _removeRecovered(device),
          ),
        ),
      PinAsk(:final display, :final parent) => (
          faceOr(null, PhosphorIconsRegular.lockKey, context, size: 44),
          'Set your PIN for shared screens',
          'So nobody at ${display.name} can act as you',
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: () => showSignInSheet(context, parent),
              child: const Text('Set PIN', maxLines: 1, softWrap: false),
            ),
          ),
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              face,
              const SizedBox(width: Sp.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.rowTitle(c.ink)),
                    if (detail.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(detail, style: t.meta(c.ink2)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Sp.m),
          actions,
          if (failed != null) ...[
            const SizedBox(height: Sp.s),
            ErrorState(message: failed, actionLabel: 'Try again', onAction: () => setState(() => _failed.remove(key))),
          ],
        ],
      ),
    );
  }

  Future<void> _undo(String key) async {
    final receipt = _settled[key]?.receipt;
    if (receipt == null) return;
    setState(() => _busy.add(key));
    final result = await context.actions.undo(receipt);
    if (!mounted) return;
    setState(() {
      _busy.remove(key);
      if (result.isError) {
        _failed[key] = result.message ?? result.text;
      } else {
        _settled.remove(key);
      }
    });
  }

  /// A device whose invite named someone joins as theirs in one tap; one that names nobody asks
  /// whose it is first.
  Future<void> _letIn(AppState app, JoinAsk need) async {
    final key = need.key;
    final who = need.member;
    if (who == null) {
      await approveDevice(context, need.device, need.name);
      final device = app.den.device(need.device);
      if (!mounted || !(device?.approved ?? false)) return;
      final owner = app.memberById(device?.member);
      final what = owner != null
          ? '${need.name} is ${FamilyWords.possessive(owner.name)}'
          : device!.mode == DeviceMode.shared
              ? '${need.name} is a shared display'
              : '${need.name} is the hub';
      setState(() => _settled[key] = _Settled(what, null));
      return;
    }
    final actions = context.actions;
    final trust = context.trustActions;
    setState(() {
      _busy.add(key);
      _failed.remove(key);
    });
    Receipt? receipt;
    final problem = await tryWrite(
      () async => receipt = await actions.record(
        'Let ${need.name} in',
        () => trust.approveDevice(need.device, member: who.id, mode: DeviceMode.personal),
      ),
    );
    if (!mounted) return;
    setState(() {
      _busy.remove(key);
      if (problem != null) {
        _failed[key] = problem;
      } else {
        _settled[key] = _Settled('${need.name} is in the family', receipt);
      }
    });
  }

  /// Someone here saw it: it stays, and this device stops saying so.
  Future<void> _acknowledge(Device device) async {
    await RecoveryNotices.acknowledge(device.id);
    if (mounted) setState(() => _settled['recovered:${device.id}'] = _Settled('${device.name} stays in the family', null));
  }

  /// A phone let in by recovery that nobody here recognizes: removed, like any other device.
  Future<void> _removeRecovered(Device device) async {
    final key = 'recovered:${device.id}';
    final trust = context.trustActions;
    setState(() {
      _busy.add(key);
      _failed.remove(key);
    });
    final problem = await tryWrite(() => trust.revokeDevice(device.id));
    if (problem == null) await RecoveryNotices.acknowledge(device.id);
    if (!mounted) return;
    setState(() {
      _busy.remove(key);
      if (problem != null) {
        _failed[key] = problem;
      } else {
        _settled[key] = _Settled('${device.name} was removed from the family', null);
      }
    });
  }

  /// Turning a device away can't be taken back: it has to ask again with a new invite.
  Future<void> _turnAway(AppState app, JoinAsk need) async {
    final key = need.key;
    final trust = context.trustActions;
    setState(() {
      _busy.add(key);
      _failed.remove(key);
    });
    final problem = await tryWrite(() => trust.revokeDevice(need.device));
    if (!mounted) return;
    setState(() {
      _busy.remove(key);
      if (problem != null) {
        _failed[key] = problem;
      } else {
        _settled[key] = _Settled('${need.name} was turned away. It can ask again with a new invite.', null);
      }
    });
  }
}
