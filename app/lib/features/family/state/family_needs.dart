import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';
import '../../../platform/sync/pairing.dart';
import 'invites.dart';
import 'recovery.dart';
import 'recovery_reminder.dart';

/// Something at the top of Family that waits for a parent on their own device, with its one
/// answer. Each keeps its [key] while it waits, so a settled one keeps its place.
sealed class FamilyNeed {
  const FamilyNeed();
  String get key;
}

/// A device asking to join, with the words its screen shows when this device holds them.
final class JoinAsk extends FamilyNeed {
  const JoinAsk({required this.device, required this.name, required this.kind, this.member, this.words = const []});

  final String device;
  final String name;
  final DeviceKind kind;

  /// Who the invite it used was for; null when it named nobody (a shared display, a hub).
  final Member? member;
  final List<String> words;

  @override
  String get key => 'device:$device';
}

/// An assistant or automation asking to connect: Review in AI and assistants.
final class ConnectionAsk extends FamilyNeed {
  const ConnectionAsk(this.connection);
  final Connection connection;

  @override
  String get key => 'connection:${connection.id}';
}

/// A parent's new phone that recovery let in, said on every other parent's own device until
/// someone there puts it away, so nobody gets in unseen: Got it, or That wasn't us (remove it).
final class RecoveredNotice extends FamilyNeed {
  const RecoveredNotice(this.device);
  final Device device;

  @override
  String get key => Recovery.noticeKey(device);
}

/// A device an invite let in by itself, said on every parent's own device until someone there
/// puts it away, so nobody gets in unseen: Got it, or That wasn't Dad (remove it).
final class InvitedNotice extends FamilyNeed {
  const InvitedNotice(this.device);
  final Device device;

  @override
  String get key => Invites.noticeKey(device);
}

/// The family has a shared screen and this parent has no PIN, so they can't act there and
/// nobody can act as them.
final class PinAsk extends FamilyNeed {
  const PinAsk(this.parent, this.display);
  final Member parent;
  final Device display;

  @override
  String get key => 'pin:${parent.id}';
}

/// This parent hasn't saved their recovery words and no other parent has a device of their own.
final class RecoveryWordsAsk extends FamilyNeed {
  const RecoveryWordsAsk();

  @override
  String get key => 'recovery-words';
}

/// One Google or Apple account bound to two people or more (bindings made while apart both
/// stand): it signs in as none of them until all but one take it away.
final class SharedAccountNotice extends FamilyNeed {
  const SharedAccountNotice(this.account, this.members);
  final AccountRef account;
  final List<Member> members;

  @override
  String get key => 'account:${account.provider}:${account.hash}';
}

/// What waits on Family for whoever uses this device: devices asking to join, connections
/// asking, and their own PIN once the family has a shared screen. Empty off a parent's own
/// device: those are trust decisions.
List<FamilyNeed> familyNeeds(AppState app, List<PendingJoin> joins) {
  if (!app.allowsTrust(DenAction.manageFamily)) return const [];
  final den = app.den;
  final words = {for (final j in joins) j.deviceId: j};
  final out = <FamilyNeed>[
    for (final d in den.pendingDevices)
      JoinAsk(device: d.id, name: d.name, kind: d.kind, member: app.memberById(d.member), words: words[d.id]?.words ?? const []),
    for (final j in joins)
      if (!den.pendingDevices.any((d) => d.id == j.deviceId))
        JoinAsk(device: j.deviceId, name: j.deviceName, kind: j.kind, words: j.words),
    for (final c in den.connections)
      if (c.status == ConnectionStatus.pending) ConnectionAsk(c),
    for (final d in Recovery.unseen(den, app.seen)) RecoveredNotice(d),
    for (final d in Invites.unseen(den, app.seen, now: den.now(), me: app.me?.id)) InvitedNotice(d),
    for (final shared in den.sharedAccounts()) SharedAccountNotice(shared.first.account!, shared),
  ];
  final me = app.me;
  final display = sharedDisplays(den).firstOrNull;
  if (me != null && me.isParent && me.signIn.kind == 'none' && display != null) out.add(PinAsk(me, display));
  if (RecoveryReminder.due(app, now: den.now())) out.add(const RecoveryWordsAsk());
  return out;
}

/// The family's shared screens that are in use: approved, not removed.
List<Device> sharedDisplays(Den den) =>
    [for (final d in den.devices) if (d.mode == DeviceMode.shared && d.approved && !d.revoked) d];

/// [member]'s own devices that are in the family.
List<Device> devicesOf(Den den, String member) => [
      for (final d in den.devices)
        if (d.member == member && d.mode == DeviceMode.personal && d.approved && !d.revoked) d,
    ];
