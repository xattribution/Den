import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';

/// What the chores screens read besides who's who.
const Set<String> choreReads = {RecordType.chore, RecordType.completion};

/// The chores on [date], computed again only when a chore or a completion changes.
class ChoresModel extends DenView<List<ChoreDay>> {
  const ChoresModel(this.date);

  final String date;

  @override
  Set<String> get reads => choreReads;

  @override
  Object get key => (ChoresModel, date);

  @override
  List<ChoreDay> compute(AppState app) => app.den.choresOn(date);
}
