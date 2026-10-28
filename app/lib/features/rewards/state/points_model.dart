import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';

/// What the points screens read besides who's who.
const Set<String> pointsReads = {
  RecordType.adjustment,
  RecordType.goal,
  RecordType.reward,
  RecordType.redemption,
  RecordType.chore,
  RecordType.completion,
};

/// Stars, goals, rewards and requests.
class PointsModel extends DenView<PointsSummary> {
  const PointsModel();

  @override
  Set<String> get reads => pointsReads;

  @override
  PointsSummary compute(AppState app) => app.den.points();
}
