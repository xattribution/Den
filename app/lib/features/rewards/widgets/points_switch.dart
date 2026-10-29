import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/widgets.dart' show SwitchLine;
import '../state/reward_actions.dart';

/// Points on or off for the whole family, for Settings, under Family (it isn't on the points
/// screen any more). Off hides every star: on chores, Today, the kids' screens and Add. Only
/// someone who may manage the family sees it working; anyone else sees it and can't change it.
///
/// Settings → Family drops this in as is; it writes through the rewards' actions, so the hub's
/// API and the assistant turn points on and off the same way.
class PointsSwitch extends StatelessWidget {
  const PointsSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.family});
    final on = app.den.family?.pointsEnabled ?? true;
    // A sentence and its switch, like every setting (SwitchLine), with what it means said
    // under it rather than behind an (i).
    return SwitchLine(
      label: 'Points and rewards',
      detail: on ? 'Stars for chores and goals, and rewards to spend them on' : 'Off: no stars show anywhere',
      value: on,
      onChanged: app.allows(DenAction.manageFamily)
          ? (v) => attempt(context, () => context.rewardActions.setPointsOn(v))
          : null,
    );
  }
}
