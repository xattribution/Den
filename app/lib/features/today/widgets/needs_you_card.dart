import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/pictograms.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../calendar/calendar.dart';
import '../../chores/chores.dart';
import '../../family/family.dart';
import '../../rewards/rewards.dart';
import '../state/needs_you.dart';
import '../words/today_words.dart';

/// Needs you (Main.dc.html): what waits for whoever is using the device, each with the one
/// action that settles it. Settling one turns its row into what it did, with Undo, in place;
/// the row stays until Today is left. Nothing waiting, no section.
class NeedsYouSection extends StatefulWidget {
  const NeedsYouSection({super.key, required this.now, this.carded = false, this.gap = 0, this.title = 'Needs you'});

  /// The heading: "Needs you", or which family in "All my families" ("Kotvas needs you").
  final String title;

  /// The current time, for which rides are still ahead.
  final int now;

  /// PadToday puts the heading inside the card.
  final bool carded;

  /// Room under the section, when there is one.
  final double gap;

  @override
  State<NeedsYouSection> createState() => _NeedsYouSectionState();
}

/// What a settled row says, and the receipt Undo takes back.
class _Settled {
  const _Settled(this.message, this.receipt);
  final String message;
  final Receipt? receipt;
}

class _NeedsYouSectionState extends State<NeedsYouSection> {
  /// Every need seen while Today is open, in the order they came, so a settled one keeps its
  /// place and an undone one comes back where it was.
  final _order = <String>[];
  final _seen = <String, Need>{};
  final _settled = <String, _Settled>{};
  final _failed = <String, String>{};
  final _busy = <String>{};

  Future<void> _settle(String key, Future<ActionResult> Function() write, String message) async {
    setState(() {
      _busy.add(key);
      _failed.remove(key);
    });
    ActionResult? result;
    final problem = await tryWrite(() async => result = await write());
    if (!mounted) return;
    setState(() {
      _busy.remove(key);
      if (problem != null) {
        _failed[key] = problem;
      } else {
        _settled[key] = _Settled(message, result?.receipt);
      }
    });
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

  @override
  Widget build(BuildContext context) {
    final needs = context.view(NeedsModel(widget.now));
    final app = DenScope.read(context);
    final live = <String, Need>{};
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
    final open = [for (final k in live.keys) if (!_settled.containsKey(k)) k].length;
    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: ruled(rows, indent: RowRule.afterFace));
    return Padding(
      padding: EdgeInsets.only(bottom: widget.gap),
      child: widget.carded
          ? _carded(context, body, open)
          : DenSection(title: widget.title, trailing: SectionCount(needCount(open)), child: body),
    );
  }

  /// PadToday's Needs you: the heading inside the card.
  Widget _carded(BuildContext context, Widget body, int open) {
    final c = context.colors;
    return GroupCard(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(child: Semantics(header: true, child: Text(widget.title, style: context.text.section(c.ink)))),
                SectionCount(needCount(open)),
              ],
            ),
          ),
          body,
        ],
      ),
    );
  }

  /// The row that asks: who or what it's about, in one sentence, and its action. A failed
  /// action says why under it, with Try again.
  Widget _ask(BuildContext context, AppState app, Need need) {
    final key = need.key;
    final busy = _busy.contains(key);
    final failed = _failed[key];
    Widget act(String label, VoidCallback run) => FilledButton(onPressed: busy ? null : run, child: Text(label, maxLines: 1, softWrap: false));
    Widget gotIt() => OutlinedButton(
          onPressed: () => app.markSeen(key),
          child: const Text('Got it', maxLines: 1, softWrap: false),
        );
    Widget go(String label, String route) => OutlinedButton(
          onPressed: () => context.push(route),
          child: Text(label, maxLines: 1, softWrap: false),
        );

    final (Widget leading, String title, String? detail, Widget action, VoidCallback? retry, VoidCallback? open) =
        switch (need) {
      RideNeed(:final occ, :final leg) => (
          _face(app, occ.assignees.firstOrNull, PhosphorIconsRegular.car),
          rideAsk(app, occ, leg),
          rideDetail(app, occ, leg),
          act('I\'ll drive', () => _takeRide(app, need)),
          () => _takeRide(app, need),
          () => context.push('/event/${occ.event.id}?at=${occ.start}'),
        ),
      RewardNeed(:final request, :final reward, :final balance) => (
          _face(app, request.member, PhosphorIconsRegular.gift),
          '${app.memberById(request.member)?.name ?? 'Someone'} wants ${inSentence(reward?.title ?? 'a reward')}',
          'Costs ${request.cost} stars, ${app.memberById(request.member)?.name ?? 'they'} has $balance',
          act('Approve', () => _approve(app, need)),
          () => _approve(app, need),
          () => context.push('/points'),
        ),
      LateNeed(:final day) => (
          _face(app, day.owner, PhosphorIconsRegular.checkCircle),
          day.chore.title,
          lateDetail(app, day),
          act('Mark done', () => _markDone(app, need)),
          () => _markDone(app, need),
          () => context.push('/chore/${day.chore.id}?date=${day.date}'),
        ),
      LateManyNeed(:final days) => (
          _glyph(context, PhosphorIconsRegular.checkCircle),
          lateSummary(app, days),
          _firstTitles(days),
          go('See them', '/chores'),
          null,
          null,
        ),
      DeviceNeed(:final device) => (
          _glyph(context, PhosphorIconsRegular.deviceMobile),
          device.member == null || app.memberById(device.member) == null
              ? '${device.name} wants to join'
              : '${device.name} wants to join as ${app.memberById(device.member)!.name}',
          device.member == null ? 'You choose whose it is' : null,
          act('Approve', () => _approveDevice(app, device)),
          () => _approveDevice(app, device),
          null,
        ),
      ConnectionNeed(:final connection) => (
          _glyph(context, PhosphorIconsRegular.plugsConnected),
          '${connection.label} wants to connect',
          connection.member == null ? 'As a parent' : 'Acting as ${app.memberById(connection.member)?.name ?? 'someone'}',
          go('Review', '/settings/connections'),
          null,
          null,
        ),
      RecoveredNeed(:final device) => (
          _face(app, recoveryOf(device)?.member, PhosphorIconsRegular.key),
          RecoveryLines.sentence(app, device),
          RecoveryLines.detail(app, device),
          gotIt(),
          null,
          () => context.push('/family/member/${recoveryOf(device)?.member ?? ''}'),
        ),
      InvitedNeed(:final device) => (
          _face(app, inviteOf(device)?.member, PhosphorIconsRegular.deviceMobile),
          InviteLines.sentence(app, device),
          InviteLines.detail(app, device),
          TwoButtons(
            primary: 'Got it',
            onPrimary: _busy.contains(key) ? null : () => _seenInvited(app, device),
            secondary: InviteLines.notThem(app, device),
            onSecondary: _busy.contains(key) ? null : () => _removeInvited(app, device),
          ),
          null,
          () => context.push('/family'),
        ),
      PrivacyNeed(:final change) => (
          _face(app, change.by, PhosphorIconsRegular.lockKey),
          privacyNotice(app.memberById(change.by)?.name ?? 'A parent', parentsSee: change.parentsSee),
          app.formats.relative(app.formats.localDate(change.at), app.today),
          gotIt(),
          null,
          null,
        ),
      AccessEndedNeed(:final member, :final until) => (
          _face(app, member.id, PhosphorIconsRegular.calendarX),
          accessEndedWords(member.name, until, app.formats, app.today),
          "${FamilyWords.possessive(member.name)} devices no longer sync",
          gotIt(),
          null,
          () => context.push('/family/member/${member.id}'),
        ),
      SignInTriesNeed(:final told) => (
          _face(app, told.member, PhosphorIconsRegular.lockKey),
          signInTriesSentence(app, told),
          signInTriesWhen(app, told),
          gotIt(),
          null,
          () => context.push('/family/member/${told.member}'),
        ),
      RecoveryWordsNeed() => (
          _glyph(context, PhosphorIconsRegular.key),
          RecoveryReminder.title,
          RecoveryReminder.detail,
          RecoveryWordsButtons(onDone: (message) => setState(() => _settled[key] = _Settled(message, null))),
          null,
          null,
        ),
      ListNeed(:final list) => (
          _glyph(context, Pictograms.listKind(list.list.kind)),
          listDue(app, list),
          itemsLeft(list.open),
          go('Open', '/lists/${list.list.id}'),
          null,
          null,
        ),
    };
    final row = ActionRow(
      leading: leading,
      title: title,
      detail: detail,
      action: failed == null ? action : null,
      onTap: open,
    );
    if (failed == null || retry == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        Padding(
          padding: const EdgeInsetsDirectional.only(start: RowRule.afterFace),
          child: ErrorState(message: failed, actionLabel: 'Try again', onAction: retry),
        ),
      ],
    );
  }

  Widget _face(AppState app, String? member, IconData otherwise) {
    final m = app.memberById(member);
    return m == null ? _glyph(context, otherwise) : DenAvatar(m, size: 40);
  }

  static Widget _glyph(BuildContext context, IconData icon) =>
      SizedBox.square(dimension: 40, child: Icon(icon, size: 26, color: context.colors.ink));

  static String _firstTitles(List<ChoreDay> days) {
    final titles = [for (final d in days.take(lateShown)) d.chore.title];
    final more = days.length - titles.length;
    return more > 0 ? '${titles.join(', ')} and $more more' : titles.join(', ');
  }

  void _takeRide(AppState app, RideNeed need) => _settle(
        need.key,
        () => context.eventActions.setRide(need.occ, need.leg, app.me?.id),
        rideTaken(app, need.occ, need.leg),
      );

  void _approve(AppState app, RewardNeed need) {
    final name = app.memberById(need.request.member)?.name ?? 'them';
    _settle(
      need.key,
      () => context.rewardActions.decide(need.request, approve: true),
      '${need.reward?.title ?? 'Reward'} approved for $name',
    );
  }

  void _markDone(AppState app, LateNeed need) {
    final owner = app.memberById(need.day.owner)?.name;
    _settle(
      need.key,
      () => context.choreActions.setDone(need.day, true),
      owner == null ? '${need.day.chore.title} marked done' : '${need.day.chore.title} marked done for $owner',
    );
  }

  /// Someone here saw a device an invite let in: it stays, and this device stops saying so.
  void _seenInvited(AppState app, Device device) {
    setState(() => _settled[Invites.noticeKey(device)] = _Settled('${device.name} stays in the family', null));
    app.markSeen(Invites.noticeKey(device));
  }

  /// "That wasn't Dad": the device is removed and the invite's key taken away. Devices it let in
  /// since are listed on Family, where they can be removed too.
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
        _failed[key] = problem ?? "That didn't work";
      } else {
        final more = done!.letIn;
        _settled[key] = _Settled(
          more.isEmpty ? InviteLines.disowned(app, device, done!) : '${InviteLines.disowned(app, device, done!)} ${RecoveryLines.letIn(more)}: see Family.',
          null,
        );
      }
    });
  }

  /// A device whose invite named someone joins as theirs in one tap; one that names nobody
  /// asks whose it is first.
  Future<void> _approveDevice(AppState app, Device device) async {
    final key = 'device:${device.id}';
    final who = app.memberById(device.member);
    if (who == null) {
      await approveDevice(context, device.id, device.name);
      if (!mounted || !(app.den.device(device.id)?.approved ?? false)) return;
      final owner = app.memberById(app.den.device(device.id)?.member);
      setState(() => _settled[key] = _Settled(owner == null ? '${device.name} joined' : '${device.name} joined as ${owner.name}', null));
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
        'Approved ${device.name}',
        () => trust.approveDevice(device.id, member: who.id, mode: DeviceMode.personal),
      ),
    );
    if (!mounted) return;
    setState(() {
      _busy.remove(key);
      if (problem != null) {
        _failed[key] = problem;
      } else {
        _settled[key] = _Settled('${device.name} joined as ${who.name}', receipt);
      }
    });
  }
}
