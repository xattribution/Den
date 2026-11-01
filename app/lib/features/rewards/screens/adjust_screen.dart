import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../design/forms/forms.dart' show FormWidth;
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../state/points_model.dart';
import '../widgets/give_stars.dart';

/// Give points on a page of its own, for a link from elsewhere (the points screen opens the
/// same form as a sheet). `/points/adjust?member=`.
class AdjustScreen extends StatelessWidget {
  const AdjustScreen({super.key, this.member, this.returnsToPoints = false});

  final String? member;

  /// Opened from the points screen: go back there instead of replacing this page with it.
  final bool returnsToPoints;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(pointsReads);
    final Widget body;
    if (!(app.den.family?.pointsEnabled ?? true)) {
      body = const EmptyState(message: 'Stars are off for this family. A parent turns them on in Settings, under Family.');
    } else if (!app.allows(DenAction.managePoints)) {
      body = const EmptyState(message: 'Giving and taking stars is for parents.');
    } else {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.xxl),
        children: [
          FormWidth(
            child: GiveStarsForm(
              member: member,
              onDone: (_) {
                if (returnsToPoints && context.canPop()) {
                  context.pop();
                } else {
                  context.pushReplacement('/points');
                }
              },
            ),
          ),
        ],
      );
    }
    return Scaffold(appBar: AppBar(), body: body);
  }
}
