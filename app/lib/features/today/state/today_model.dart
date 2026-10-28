import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';

/// What Today reads besides who's who.
const Set<String> todayReads = {
  RecordType.event,
  RecordType.eventException,
  RecordType.category,
  RecordType.chore,
  RecordType.completion,
  RecordType.list,
  RecordType.item,
  RecordType.reward,
  RecordType.redemption,
};

/// Today's plan: events, gaps, chores and lists, computed again only when what it reads changes.
class TodayModel extends DenView<TodayView> {
  const TodayModel();

  @override
  Set<String> get reads => todayReads;

  @override
  TodayView compute(AppState app) => app.den.today();
}
