import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';

/// What the lists screens read besides who's who (a list for an event names it).
const Set<String> listReads = {RecordType.list, RecordType.item, RecordType.event, RecordType.eventException};

/// Every list the person using the device can see, with its items.
class ListsModel extends DenView<List<ListState>> {
  const ListsModel();

  @override
  Set<String> get reads => listReads;

  @override
  List<ListState> compute(AppState app) => app.den.lists;
}
