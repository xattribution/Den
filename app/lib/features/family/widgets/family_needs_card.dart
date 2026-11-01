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
import '../state/invites.dart';
import '../state/recovery.dart';
import '../state/recovery_reminder.dart';
import '../state/trust_actions.dart';
import '../words/family_words.dart';
import '../words/invite_lines.dart';
import '../words/recovery_lines.dart';
import 'family_parts.dart';
import 'person_sheets.dart';
import 'recovery_reminder.dart';

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
  const _Settled(this.message, this.receipt, {this.letIn = const []});
  final String message;
  final Receipt? receipt;

  /// After "That wasn't us": the devices the removed phone let in, still in the family, which
  /// the row offers to remove too.
  final List<Device> letIn;
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
                  : settled.letIn.isNotEmpty
                      ? _letInRow(context, key, settled)
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

  /// "It isn't mine": takes this parent's binding of a shared account away, so it is the
  /// others' again.
  Future<void> _notMyAccount(AppState app, FamilyNeed need) async {
    final me = app.me;
    if (me == null) return;
    final trust = context.trustActions;
    final key = need.key;
    setState(() {
      _busy.add(key);
      _failed.remove(key);
    });
    final problem = await tryWrite(() => trust.setAccount(me.id, null));
    if (!mounted) return;
    setState(() {
      _busy.remove(key);
      if (problem != null) {
        _failed[key] = problem;
      } else {
        _settled[key] = _Settled('It no longer signs in as you', null);
      }
    });
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
            primary: 'Approve',
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
            primary: 'Got it',
            onPrimary: busy ? null : () => _acknowledge(app, device),
            secondary: "That wasn't us",
            onSecondary: busy ? null : () => _removeRecovered(app, device),
          ),
        ),
      InvitedNotice(:final device) => (
          faceOr(app.memberById(inviteOf(device)?.member), Pictograms.device(device.kind), context, size: 44),
          InviteLines.sentence(app, device),
          InviteLines.detail(app, device),
          TwoButtons(
            primary: 'Got it',
            onPrimary: busy ? null : () => _acknowledgeInvited(app, device),
            secondary: InviteLines.notThem(app, device),
            onSecondary: busy ? null : () => _removeInvited(app, device),
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
      SharedAccountNotice(:final account, :final members) => (
          faceOr(null, PhosphorIconsRegular.signIn, context, size: 44),
          'One ${account.provider == 'apple' ? 'Apple' : 'Google'} account signs in as ${FamilyWords.joinAnd([for (final m in members) m.name])}',
          'So it signs in as none of them. Whoever it isn\'t takes it away.',
          members.any((m) => m.id == app.me?.id)
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: busy ? null : () => _notMyAccount(app, need),
                    child: const Text('It isn\'t mine', maxLines: 1, softWrap: false),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      RecoveryWordsAsk() => (
          faceOr(null, PhosphorIconsRegular.key, context, size: 44),
          RecoveryReminder.title,
          RecoveryReminder.detail,
          RecoveryWordsButtons(onDone: (message) => setState(() => _settled[key] = _Settled(message, null))),
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
        'Approved ${need.name}',
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
  void _acknowledge(AppState app, Device device) {
    setState(() => _settled[Recovery.noticeKey(device)] = _Settled('${device.name} stays in the family', null));
    app.markSeen(Recovery.noticeKey(device));
  }

  /// A phone let in by recovery that nobody here recognizes: removed, and the words or the
  /// hub's help that let it in turned off, so whoever used them can't do it again. The row then
  /// says so, and names any device the phone let in meanwhile, with Remove them too.
  Future<void> _removeRecovered(AppState app, Device device) async {
    final key = Recovery.noticeKey(device);
    final trust = context.trustActions;
    setState(() {
      _busy.add(key);
      _failed.remove(key);
    });
    DisownedRecovery? done;
    final problem = await tryWrite(() async => done = await trust.thatWasntUs(device.id));
    if (problem == null) app.markSeen(key);
    if (!mounted) return;
    setState(() {
      _busy.remove(key);
      if (problem != null || done == null) {
        _failed[key] = problem ?? 'That didn\'t work';
      } else {
        _settled[key] = _Settled(RecoveryLines.disowned(app, device, done!), null, letIn: done!.letIn);
      }
    });
  }

  /// Someone here saw a device an invite let in: it stays, and this device stops saying so.
  void _acknowledgeInvited(AppState app, Device device) {
    setState(() => _settled[Invites.noticeKey(device)] = _Settled('${device.name} stays in the family', null));
    app.markSeen(Invites.noticeKey(device));
  }

  /// A device an invite let in that nobody here recognizes: removed, and the invite's key taken
  /// away, so whoever used it can't use it again. The row then says so, and names any device it
  /// let in meanwhile, with Remove them too.
  Future<void> _removeInvited(AppState app, Device device) async {
    final key = Invites.noticeKey(device);
    final trust = context.trustActions;
    setState(() {
      _busy.add(key);
      _failed.remove(key);
    });
    DisownedInvite? done;
    final problem = await tryWrite(() async => done = await trust.thatWasntThem(device.id));
    if (problem == null) app.markSeen(key);
    if (!mounted) return;
    setState(() {
      _busy.remove(key);
      if (problem != null || done == null) {
        _failed[key] = problem ?? 'That didn\'t work';
      } else {
        _settled[key] = _Settled(InviteLines.disowned(app, device, done!), null, letIn: done!.letIn);
      }
    });
  }

  /// What "That wasn't us" did, and the devices the removed phone let in, with Remove them too.
  Widget _letInRow(BuildContext context, String key, _Settled settled) {
    final c = context.colors;
    final busy = _busy.contains(key);
    final failed = _failed[key];
    final many = settled.letIn.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DoneRow(message: settled.message),
        Padding(
          padding: const EdgeInsets.only(left: 22 + Sp.m),
          child: Text(RecoveryLines.letIn(settled.letIn), style: context.text.meta(c.ink2)),
        ),
        const SizedBox(height: Sp.m),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: busy ? null : () => _removeLetIn(key, settled),
            child: Text(many ? 'Remove them too' : 'Remove it too', maxLines: 1, softWrap: false),
          ),
        ),
        if (failed != null) ...[
          const SizedBox(height: Sp.s),
          ErrorState(message: failed, actionLabel: 'Try again', onAction: () => setState(() => _failed.remove(key))),
        ],
        const SizedBox(height: Sp.l),
      ],
    );
  }

  Future<void> _removeLetIn(String key, _Settled settled) async {
    final trust = context.trustActions;
    final devices = settled.letIn;
    setState(() {
      _busy.add(key);
      _failed.remove(key);
    });
    final problem = await tryWrite(() => trust.removeDevices([for (final d in devices) d.id]));
    if (!mounted) return;
    setState(() {
      _busy.remove(key);
      if (problem != null) {
        _failed[key] = problem;
      } else {
        _settled[key] = _Settled('${settled.message} ${RecoveryLines.letInRemoved(devices)}', null);
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
