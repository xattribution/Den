import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/actions.dart';
import '../../../app/den_scope.dart';

/// Every change the points screens make (and the kids' screens make to rewards), each one a
/// den_actions action.
class RewardActions {
  const RewardActions(this._actions);

  final AppActions _actions;

  /// Gives (positive) or takes (negative) [delta] stars from [member], with a [reason].
  Future<ActionResult> adjust(String member, int delta, String reason) =>
      _actions.run('adjust_points', {'person': member, 'delta': delta, 'reason': reason});

  /// Adds a goal, or changes [existing]. [end] is the last day; null for open-ended.
  Future<ActionResult> saveGoal(
    Goal? existing, {
    required String title,
    required int target,
    required GoalMode mode,
    required List<String>? members,
    required String? start,
    required String? end,
    required GoalRepeat repeat,
    required String reward,
  }) =>
      _actions.run('save_goal', {
        if (existing != null) 'goal': existing.id,
        'title': title,
        'target': target,
        'mode': mode.name,
        'people': members ?? const <String>[],
        'start': start,
        'end': end ?? '',
        'repeat': repeat.name,
        'reward': reward,
      });

  /// Removes [goal]; its receipt brings it back.
  Future<ActionResult> deleteGoal(Goal goal) => _actions.run('delete_goal', {'goal': goal.id});

  /// Adds a reward, or changes [existing].
  Future<ActionResult> saveReward(
    Reward? existing, {
    required String title,
    required int cost,
    required String icon,
    required bool needsApproval,
  }) =>
      _actions.run('save_reward', {
        if (existing != null) 'reward': existing.id,
        'title': title,
        'cost': cost,
        // A pictogram another app stored stays as it is unless someone picks a new one.
        if (existing == null || icon != existing.icon) 'icon': icon,
        'needs_approval': needsApproval,
      });

  /// Retires [reward] (or brings it back with [active]); stars already spent stay spent.
  Future<ActionResult> setRewardActive(Reward reward, bool active) =>
      _actions.run('save_reward', {'reward': reward.id, 'active': active});

  /// Spends [member]'s stars on [reward] (the person using the device when null).
  Future<ActionResult> request(Reward reward, {String? member}) =>
      _actions.run('request_reward', {'reward': reward.id, 'person': member});

  /// Approves or declines a reward request.
  Future<ActionResult> decide(Redemption request, {required bool approve}) =>
      _actions.run('decide_reward_request', {'request': request.id, 'approve': approve});

  /// Turns stars on or off for the family.
  Future<ActionResult> setPointsOn(bool on) => _actions.run('update_family_settings', {'points_enabled': on});
}

extension RewardActionsOf on BuildContext {
  /// The points' actions. Reading them never rebuilds.
  RewardActions get rewardActions => RewardActions(actions);
}
