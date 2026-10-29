import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';
import '../../calendar/calendar_words.dart';
import '../../family/family.dart' show Recovery, RecoveryNotices;

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

/// A parent's new phone that recovery let in, on another parent's own device: "OK".
final class RecoveredNeed extends Need {
  const RecoveredNeed(this.device);
  final Device device;

  @override
  String get key => 'recovered:${device.id}';
}

/// A dated list due today or tomorrow with things left on it: "Open".
final class ListNeed extends Need {
  const ListNeed(this.list);
  final ListState list;

  @override
  String get key => 'list:${list.list.id}';
}

/// How many late chores Needs you lists one by one before it sums them up.
const int lateShown = 3;

/// What waits for whoever is using the device, most pressing first: rides in the next 48 hours,
/// reward requests (when stars are on), late chores (today's and yesterday's), devices and AI
/// connections asking to join, and lists due. Each only for someone who may settle it.
List<Need> needsYou(AppState app, {required int now}) {
  final den = app.den;
  if (app.me == null) return const [];
  final out = <Need>[];

  if (canTakeRide(app)) {
    for (final gap in den.gaps(now, now + 48 * 3600000)) {
      if (gap.kind != GapKind.noDriver || gap.occurrences.isEmpty || gap.leg == null) continue;
      final occ = gap.occurrences.single;
      if (occ.event.source.readOnly) continue;
      final at = gap.leg == 'from' ? occ.end : occ.start;
      if (at < now) continue;
      out.add(RideNeed(occ, gap.leg!));
    }
  }

  final pointsOn = den.family?.pointsEnabled ?? true;
  if (pointsOn && app.allows(DenAction.managePoints)) {
    final points = den.points();
    final rewards = {for (final r in den.rewards) r.id: r};
    for (final r in points.pending) {
      out.add(RewardNeed(r, rewards[r.reward], points.totals[r.member] ?? 0));
    }
  }

  if (app.allows(DenAction.completeAnyChore)) {
    final late = den.lateChores(days: 1);
    if (late.length > lateShown) {
      out.add(LateManyNeed(late));
    } else {
      out.addAll(late.map(LateNeed.new));
    }
  }

  if (app.allowsTrust(DenAction.manageFamily)) {
    out.addAll(den.pendingDevices.map(DeviceNeed.new));
    out.addAll([for (final c in den.connections) if (c.status == ConnectionStatus.pending) ConnectionNeed(c)]);
    out.addAll([
      for (final d in Recovery.letIn(den))
        if (d.id != den.deviceId && !RecoveryNotices.seen.value.contains(d.id)) RecoveredNeed(d),
    ]);
  }

  final today = app.today;
  final tomorrow = app.formats.addDays(today, 1);
  for (final l in den.lists) {
    final needBy = l.list.needBy;
    if (l.list.lifecycle != ListLifecycle.dated || needBy == null) continue;
    if (needBy.compareTo(today) < 0 || needBy.compareTo(tomorrow) > 0 || l.open == 0) continue;
    out.add(ListNeed(l));
  }
  return out;
}

/// [needsYou], computed again only when what it reads changes or the hour turns.
class NeedsModel extends DenView<List<Need>> {
  const NeedsModel(this.now);

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
      };

  @override
  Object get key => (NeedsModel, now ~/ 3600000, RecoveryNotices.seen.value.length);

  @override
  List<Need> compute(AppState app) => needsYou(app, now: now);
}
