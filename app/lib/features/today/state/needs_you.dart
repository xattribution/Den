import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';
import '../../calendar/calendar_words.dart';
import '../../family/family.dart' show Invites, Recovery, RecoveryReminder;

/// Something on Today that waits for the person using the device, with one action that settles
/// it. Each has a [key] that stays the same while it waits, so a settled one keeps its place.
sealed class Need {
  const Need();
  String get key;
}

/// A ride leg in the next two days that nobody is driving: "I'll drive".
final class RideNeed extends Need {
  const RideNeed(this.occ, this.leg);
  final Occurrence occ;
  final String leg;

  @override
  String get key => 'ride:${occ.event.id}@${occ.start}:$leg';

  /// When the ride leaves: the start for the way there, the end for the way back.
  int get leaves => leg == 'from' ? occ.end : occ.start;
}

/// A kid asking to spend stars on a reward: "Approve".
final class RewardNeed extends Need {
  const RewardNeed(this.request, this.reward, this.balance);
  final Redemption request;
  final Reward? reward;

  /// What the kid has now, before this request.
  final int balance;

  @override
  String get key => 'reward:${request.id}';
}

/// A chore from today past its due time, or from yesterday, not done: "Mark done".
final class LateNeed extends Need {
  const LateNeed(this.day);
  final ChoreDay day;

  @override
  String get key => 'late:${day.chore.id}@${day.date}';
}

/// More late chores than Needs you lists one by one: "See them".
final class LateManyNeed extends Need {
  const LateManyNeed(this.days);
  final List<ChoreDay> days;

  @override
  String get key => 'late:many';
}

/// A device asking to join: "Approve".
final class DeviceNeed extends Need {
  const DeviceNeed(this.device);
  final Device device;

  @override
  String get key => 'device:${device.id}';
}

/// An AI or automation connection waiting for a parent: "Review".
final class ConnectionNeed extends Need {
  const ConnectionNeed(this.connection);
  final Connection connection;

  @override
  String get key => 'connection:${connection.id}';
}

/// A parent's new phone that recovery let in, on another parent's own device: "Got it".
final class RecoveredNeed extends Need {
  const RecoveredNeed(this.device);
  final Device device;

  @override
  String get key => Recovery.noticeKey(device);
}

/// A device an invite let in by itself, on a parent's own device: "Got it", or "That wasn't
/// Dad", which removes it.
final class InvitedNeed extends Need {
  const InvitedNeed(this.device);
  final Device device;

  @override
  String get key => Invites.noticeKey(device);
}

/// A dated list due today or tomorrow with things left on it: "Open".
final class ListNeed extends Need {
  const ListNeed(this.list);
  final ListState list;

  @override
  String get key => 'list:${list.list.id}';
}

/// A parent changed whether parents see this person's "Just me" items: "Got it".
final class PrivacyNeed extends Need {
  const PrivacyNeed(this.change);
  final PrivacyChange change;

  @override
  String get key => 'privacy:${change.change}';
}

/// A sitter's last day has passed and this device removed their devices: "Got it".
final class AccessEndedNeed extends Need {
  const AccessEndedNeed(this.member, this.until);
  final Member member;
  final String until;

  @override
  String get key => 'ended:${member.id}:$until';
}

/// A shared screen saw someone get a person's PIN or pattern wrong ten times in a row, said on
/// a parent's own phone: "Got it".
final class SignInTriesNeed extends Need {
  const SignInTriesNeed(this.told);
  final SignInTries told;

  @override
  String get key => 'tries:${told.id}';
}

/// This parent hasn't saved their recovery words and no other parent has a device of their own
/// (`RecoveryReminder`): "Save them", or "Remind me later".
final class RecoveryWordsNeed extends Need {
  const RecoveryWordsNeed(this.member);
  final String member;

  @override
  String get key => RecoveryReminder.snoozeKey(member);
}

/// How long a privacy change or a sitter's ended access stays in Needs you unless put away.
const int noticeDays = 14;

/// How many late chores Needs you lists one by one before it sums them up.
const int lateShown = 3;

/// How many things Needs you shows before "2 more", which opens the rest in place.
const int needsShown = 3;

/// What waits for whoever is using the device, most pressing first (HOUSEMOM_PASS.md): a change
/// a parent made to their privacy; rides in the next 48 hours, soonest first; then whoever waits
/// on an answer right now: a device asking to join, a kid asking for a reward (when stars are
/// on); lists due, today's before tomorrow's; late chores (today's and yesterday's, a grown-up's
/// or anyone's, never a kid's); AI connections asking to connect; then what only needs a "Got
/// it" (devices an invite let in, recovered phones, sign-in tries, sitters whose access ended);
/// and last the reminder to save recovery words. Each only for someone who may settle it, and
/// none that was put off until tomorrow on this device ([putOff]).
List<Need> needsYou(AppState app, {required int now}) {
  final den = app.den;
  if (app.me == null) return const [];
  final out = <Need>[];

  // Someone told that a parent changed their privacy, until they say they've seen it.
  final me = app.me!;
  final privacy = den.privacyChange(me.id);
  if (privacy != null &&
      privacy.by != me.id &&
      now - privacy.at < noticeDays * 86400000 &&
      !app.seen(PrivacyNeed(privacy).key)) {
    out.add(PrivacyNeed(privacy));
  }

  if (canTakeRide(app)) {
    final rides = <(int, RideNeed)>[];
    for (final gap in den.gaps(now, now + 48 * 3600000)) {
      if (gap.kind != GapKind.noDriver || gap.occurrences.isEmpty || gap.leg == null) continue;
      final occ = gap.occurrences.single;
      if (occ.event.source.readOnly) continue;
      final at = gap.leg == 'from' ? occ.end : occ.start;
      if (at < now) continue;
      rides.add((at, RideNeed(occ, gap.leg!)));
    }
    rides.sort((a, b) => a.$1.compareTo(b.$1));
    out.addAll(rides.map((r) => r.$2));
  }

  final parentHere = app.allowsTrust(DenAction.manageFamily);
  // Someone holding a phone or tablet, waiting to be let in.
  if (parentHere) out.addAll(den.pendingDevices.map(DeviceNeed.new));

  final pointsOn = den.family?.pointsEnabled ?? true;
  if (pointsOn && app.allows(DenAction.managePoints)) {
    final points = den.points();
    final rewards = {for (final r in den.rewards) r.id: r};
    for (final r in points.pending) {
      out.add(RewardNeed(r, rewards[r.reward], points.totals[r.member] ?? 0));
    }
  }

  final today = app.today;
  final tomorrow = app.formats.addDays(today, 1);
  final due = <(String, ListNeed)>[];
  for (final l in den.lists) {
    final needBy = l.list.needBy;
    if (l.list.lifecycle != ListLifecycle.dated || needBy == null) continue;
    if (needBy.compareTo(today) < 0 || needBy.compareTo(tomorrow) > 0 || l.open == 0) continue;
    due.add((needBy, ListNeed(l)));
  }
  due.sort((a, b) => a.$1.compareTo(b.$1));
  out.addAll(due.map((d) => d.$2));

  if (app.allows(DenAction.completeAnyChore)) {
    // A kid's chore never nags a grown-up here ("she can go check them if she wants"): the
    // Chores tab still shows it late. A grown-up's own, or one for anyone, still waits here.
    final late = [
      for (final d in den.lateChores(days: 1))
        if (!(app.memberById(d.owner)?.isKid ?? false)) d,
    ];
    if (late.length > lateShown) {
      out.add(LateManyNeed(late));
    } else {
      out.addAll(late.map(LateNeed.new));
    }
  }

  if (parentHere) {
    out.addAll([for (final c in den.connections) if (c.status == ConnectionStatus.pending) ConnectionNeed(c)]);
    out.addAll(Invites.unseen(den, app.seen, now: now, me: me.id).map(InvitedNeed.new));
    out.addAll(Recovery.unseen(den, app.seen).map(RecoveredNeed.new));
    out.addAll(_triesToTell(app, now).map(SignInTriesNeed.new));
    final since = app.formats.addDays(app.today, -noticeDays);
    for (final m in den.members) {
      final until = m.until;
      if (until == null || !m.accessEndedOn(app.today) || until.compareTo(since) < 0) continue;
      final need = AccessEndedNeed(m, until);
      if (!app.seen(need.key)) out.add(need);
    }
    if (RecoveryReminder.due(app, now: now)) out.add(RecoveryWordsNeed(me.id));
  }
  // What she swiped away or put off with the × ("Not now") waits until tomorrow.
  return [
    for (final n in out)
      if (!putOff(app, n, now: now)) n,
  ];
}

/// Whether [need] was put off ("Not now") on this device until a time still ahead.
bool putOff(AppState app, Need need, {required int now}) {
  final until = app.snoozedUntil(need.key);
  return until != null && now < until;
}

/// When "Not now" brings [need] back: a ride an hour before it leaves (a kid must never be
/// left without one), anything else at the start of tomorrow, in the family's time zone.
int notNowUntil(AppState app, Need need) => switch (need) {
      RideNeed() => need.leaves - rideBackBefore.inMilliseconds,
      _ => app.den.dayStart(app.formats.addDays(app.today, 1)),
    };

/// How long before a ride leaves a "Not now" on it ends.
const Duration rideBackBefore = Duration(hours: 1);

/// Whether "Not now" can put [need] off at all: not a ride that leaves within the hour.
bool canPutOff(AppState app, Need need, {required int now}) => notNowUntil(app, need) > now;

/// What shared screens said about wrong tries in the last [noticeDays] that this device hasn't
/// put away: the newest for each screen and person.
List<SignInTries> _triesToTell(AppState app, int now) {
  final newest = <(String, String), SignInTries>{};
  for (final t in app.den.signInTries) {
    if (now - t.at > noticeDays * 86400000) continue;
    newest.putIfAbsent((t.device, t.member), () => t);
  }
  return [
    for (final t in newest.values)
      if (app.memberById(t.member) != null && !app.seen(SignInTriesNeed(t).key)) t,
  ];
}

/// [needsYou], computed again only when what it reads changes or the hour turns.
class NeedsModel extends DenView<List<Need>> {
  const NeedsModel(this.now, {this.ended = 0});

  /// How many put-off things have come back by [now] ([AppState.snoozesEnded]), so one coming
  /// back mid-hour (a ride an hour before it leaves) shows at once.
  final int ended;

  /// The current time; the view is kept for the hour it falls in.
  final int now;

  @override
  Set<String> get reads => const {
        RecordType.event,
        RecordType.eventException,
        RecordType.chore,
        RecordType.completion,
        RecordType.adjustment,
        RecordType.reward,
        RecordType.redemption,
        RecordType.list,
        RecordType.item,
        RecordType.connection,
        RecordType.signInTries,
        RecordType.inviteKey,
        Changes.notices,
      };

  @override
  Object get key => (NeedsModel, now ~/ 3600000, ended);

  @override
  List<Need> compute(AppState app) => needsYou(app, now: now);
}
