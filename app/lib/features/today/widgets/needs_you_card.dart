import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
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
///
/// The first [needsShown] show; "2 more" under them opens the rest in place. A row that asks a
/// yes or no (a reward, a device asking to join) also answers by a swipe, to the right for yes
/// and to the left for no, and its small × says no too; a row with no no is put off until
/// tomorrow by the swipe left or the × ("Not now"). What a swipe or the × did shows in the row's
/// place with Undo for [undoWindow]; a no is only sent once that has passed (or Today closes),
/// and then the row folds away.
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

  /// How long Undo stays after a swipe or the ×, before a no is sent and the row folds away.
  @visibleForTesting
  static Duration undoWindow = const Duration(seconds: 5);

  @override
  State<NeedsYouSection> createState() => _NeedsYouSectionState();
}

/// What a settled row says, and how Undo takes it back: the receipt of what was written, or
/// [undo] for something only this device did or a no that hasn't been sent yet.
class _Settled {
  const _Settled(this.message, this.receipt, {this.undo});
  final String message;
  final Receipt? receipt;
  final VoidCallback? undo;
}

class _NeedsYouSectionState extends State<NeedsYouSection> {
  /// Every need seen while Today is open, in the order they came, so a settled one keeps its
  /// place and an undone one comes back where it was.
  final _order = <String>[];
  final _seen = <String, Need>{};
  final _settled = <String, _Settled>{};
  final _failed = <String, String>{};
  final _busy = <String>{};

  /// What a failed no tries again, by key.
  final _again = <String, VoidCallback>{};

  /// The rows a swipe or the × put away, waiting out Undo: their timers, and the no to send
  /// when it ends (null for "Not now", which this device already did).
  final _waiting = <String, (Timer, Future<void> Function()?)>{};

  /// Rows put away for good, folding out of the list.
  final _gone = <String>{};

  /// "2 more" was tapped: every row shows.
  bool _all = false;

  @override
  void dispose() {
    // Today closing ends Undo: what was declined is sent now.
    for (final (timer, send) in _waiting.values) {
      timer.cancel();
      if (send != null) unawaited(tryWrite(send));
    }
    _waiting.clear();
    super.dispose();
  }

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
    final settled = _settled[key];
    if (settled == null) return;
    final local = settled.undo;
    if (local != null) {
      _waiting.remove(key)?.$1.cancel();
      local();
      setState(() => _settled.remove(key));
      return;
    }
    final receipt = settled.receipt;
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

  /// Puts [key]'s row away with [message] and Undo, for [NeedsYouSection.undoWindow]: then
  /// [send] (a no, written only now) and the row folds away. [undo] takes back what this device
  /// did at once (a "Not now").
  void _putAway(String key, String message, {Future<void> Function()? send, VoidCallback? undo}) {
    _waiting.remove(key)?.$1.cancel();
    final timer = Timer(NeedsYouSection.undoWindow, () => _undoEnded(key));
    setState(() {
      _failed.remove(key);
      _again.remove(key);
      _waiting[key] = (timer, send);
      _settled[key] = _Settled(message, null, undo: undo ?? () {});
    });
  }

  Future<void> _undoEnded(String key) async {
    final waiting = _waiting.remove(key);
    if (waiting == null || !mounted) return;
    final send = waiting.$2;
    if (send != null) {
      final problem = await tryWrite(send);
      if (!mounted) return;
      if (problem != null) {
        // Not sent: the row comes back, saying why, with Try again.
        setState(() {
          _settled.remove(key);
          _failed[key] = problem;
        });
        return;
      }
    }
    setState(() {
      final s = _settled[key];
      if (s != null) _settled[key] = _Settled(s.message, null);
      _gone.add(key);
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
    final first = <Widget>[];
    final rest = <Widget>[];
    var shown = 0;
    for (final key in _order) {
      final settled = _settled[key];
      final need = live[key] ?? (settled != null ? _seen[key] : null);
      if (need == null) continue;
      final gone = _gone.contains(key);
      final receipt = settled?.receipt;
      final waiting = _waiting.containsKey(key);
      final undo = !_busy.contains(key) && (waiting || (receipt != null && receipt.undoable)) ? () => _undo(key) : null;
      final row = KeyedSubtree(
        key: ValueKey(key),
        child: DenReveal(
          visible: !gone,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A hairline over every row but the first.
              if (shown > 0 || gone && first.isNotEmpty) const RowRule(indent: RowRule.afterFace),
              DoneSwap(
                done: settled == null ? null : DoneRow(message: settled.message, onUndo: gone ? null : undo),
                child: _ask(context, app, need),
              ),
            ],
          ),
        ),
      );
      if (gone || shown < needsShown) {
        first.add(row);
      } else {
        rest.add(row);
      }
      if (!gone) shown++;
    }
    if (first.isEmpty) return const SizedBox.shrink();
    final open = [for (final k in live.keys) if (!_settled.containsKey(k)) k].length;
    final c = context.colors;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...first,
        if (rest.isNotEmpty) ...[
          DenReveal(visible: _all, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rest)),
          DenReveal(
            visible: !_all,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const RowRule(indent: RowRule.afterFace),
                DenPressable(
                  onTap: () => setState(() => _all = true),
                  scale: false,
                  shape: const RoundedRectangleBorder(),
                  semanticLabel: 'Show ${needsMore(rest.length)}',
                  child: ExcludeSemantics(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 52),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(start: RowRule.afterFace),
                        child: Row(
                          children: [
                            Text(needsMore(rest.length), style: context.text.label(c.ink)),
                            const SizedBox(width: Sp.xs),
                            Icon(PhosphorIconsBold.caretDown, size: 16, color: c.ink),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
    // Once the last row has folded away, the section folds with it.
    return DenReveal(
      visible: shown > 0,
      child: Padding(
        padding: EdgeInsets.only(bottom: widget.gap),
        child: widget.carded
            ? _carded(context, body, open)
            : DenSection(title: widget.title, trailing: SectionCount(needCount(open)), child: body),
      ),
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
    // The swipes and the ×: a yes or no where the row asks one (the same calls as its buttons,
    // so the same rules decide who may), and "Not now" everywhere else. A row whose own buttons
    // already put it away ("Got it", "Remind me later") gets the swipe and no ×.
    final (VoidCallback? yes, VoidCallback no, String noLabel, bool cross) = switch (need) {
      RewardNeed() => (() => _approve(app, need), () => _decline(app, need), 'Decline', true),
      DeviceNeed(:final device) => (() => _approveDevice(app, device), () => _turnAway(app, device), 'Turn away', true),
      RideNeed() || LateNeed() || LateManyNeed() || ListNeed() || ConnectionNeed() => (null, () => _notNow(app, need), 'Not now', true),
      _ => (null, () => _notNow(app, need), 'Not now', false),
    };
    final row = ActionRow(
      leading: leading,
      title: title,
      detail: detail,
      action: failed == null ? action : null,
      onTap: open,
      // Two buttons beside the words would leave the words a sliver of an iPad column.
      actionBelow: need is RecoveryWordsNeed ? true : null,
      onApprove: busy ? null : yes,
      onDecline: busy ? null : no,
      declineLabel: noLabel,
      declineButton: cross,
    );
    final again = _again[key] ?? retry;
    if (failed == null || again == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        Padding(
          padding: const EdgeInsetsDirectional.only(start: RowRule.afterFace),
          child: ErrorState(message: failed, actionLabel: 'Try again', onAction: again),
        ),
      ],
    );
  }

  /// "Not now": put off on this device until tomorrow, at once, with Undo for a few seconds.
  void _notNow(AppState app, Need need) {
    final key = need.key;
    app.snooze(key, notNowUntil(app));
    _putAway(key, notNowDone, undo: () => app.unsnooze(key));
  }

  /// No to a reward: sent once Undo has gone, so a swipe by mistake never reaches the kid.
  void _decline(AppState app, RewardNeed need) {
    final rewards = context.rewardActions;
    final name = app.memberById(need.request.member)?.name ?? 'them';
    final id = need.request.id;
    _putAway(
      need.key,
      rewardDeclined(need.reward?.title ?? 'Reward', name),
      send: () async {
        // Someone else may have answered meanwhile.
        if (!app.den.points().pending.any((r) => r.id == id)) return;
        final result = await rewards.decide(need.request, approve: false);
        if (result.isError) throw InvalidInput(result.message ?? result.text);
      },
    );
    _again[need.key] = () => _decline(app, need);
  }

  /// A device asking to join turned away, as Family's "Turn it away": it can ask again with a
  /// new invite, and that can't be taken back, so it is sent only once Undo has gone. Only ever
  /// shown on a parent's own device, as Approve is.
  void _turnAway(AppState app, Device device) {
    final trust = context.trustActions;
    final id = device.id;
    _putAway(
      'device:$id',
      deviceTurnedAway(device.name),
      send: () async {
        // Approved or removed meanwhile (another parent, Family): leave it be.
        final now = app.den.device(id);
        if (now == null || now.approved || now.revoked) return;
        await trust.revokeDevice(id);
      },
    );
    _again['device:$id'] = () => _turnAway(app, device);
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
