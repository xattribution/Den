import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';

/// What the calendar reads besides who's who (the family week shows chores too).
const Set<String> calendarReads = {
  RecordType.event,
  RecordType.eventException,
  RecordType.category,
  RecordType.subscription,
  RecordType.chore,
  RecordType.completion,
};

const Set<String> _eventReads = {RecordType.event, RecordType.eventException, RecordType.category, RecordType.subscription};

/// Occurrences from [start] to [end] (UTC milliseconds), computed again only when an event
/// changes.
class OccurrencesModel extends DenView<List<Occurrence>> {
  const OccurrencesModel(this.start, this.end);

  final int start;
  final int end;

  @override
  Set<String> get reads => _eventReads;

  @override
  Object get key => (OccurrencesModel, start, end);

  @override
  List<Occurrence> compute(AppState app) => app.den.occurrences(start, end);
}

/// The family week from [startDate]: everyone's events and chores, day by day.
class WeekModel extends DenView<WeekGrid> {
  const WeekModel(this.startDate, {this.days = 7});

  final String startDate;
  final int days;

  @override
  Set<String> get reads => calendarReads;

  @override
  Object get key => (WeekModel, startDate, days);

  @override
  WeekGrid compute(AppState app) => app.den.week(startDate, days: days);
}
