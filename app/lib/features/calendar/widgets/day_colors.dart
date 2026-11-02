import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../words/calendar_time.dart';

/// Who has something on a day, for the month drawn in colors: whether anything is for everyone,
/// and the people with something of their own, in the family's order.
class DayPeople {
  const DayPeople({this.everyone = false, this.people = const []});

  static const none = DayPeople();

  final bool everyone;
  final List<Member> people;

  bool get isEmpty => !everyone && people.isEmpty;

  /// The most people a day shows as colors; past that, the first [shownWhenMore] and "+N".
  static const int most = 3;
  static const int shownWhenMore = 2;

  /// The people drawn as colors: everyone up to [most], or the first [shownWhenMore].
  List<Member> get shown => people.length > most ? people.sublist(0, shownWhenMore) : people;

  /// How many people "+N" stands for; 0 when everyone with something is drawn.
  int get more => people.length - shown.length;

  /// "Leo and Mia", "Everyone": what a screen reader says about the day.
  String get words {
    if (everyone) return 'something for everyone';
    final names = [for (final m in people) m.name];
    if (names.length == 1) return names.single;
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }
}

/// Whether [occ] is for the whole family: nobody named, or everyone named (as event blocks
/// count it).
bool forEveryone(Occurrence occ, List<Member> family) =>
    occ.assignees.isEmpty || (family.length > 1 && family.every((m) => occ.assignees.contains(m.id)));

/// Who has something on [date] among [occurrences]. [person] narrows it to one person's events
/// and everyone's.
DayPeople dayPeople(AppState app, List<Occurrence> occurrences, String date, {String? person}) {
  final f = app.formats;
  final family = app.den.members;
  var everyone = false;
  final ids = <String>{};
  for (final occ in occurrences) {
    if (f.localDate(occ.start).compareTo(date) > 0 || f.lastDate(occ.start, occ.end).compareTo(date) < 0) continue;
    if (forEveryone(occ, family)) {
      everyone = true;
      continue;
    }
    if (person != null && !occ.assignees.contains(person)) continue;
    ids.addAll(occ.assignees);
  }
  if (!everyone && ids.isEmpty) return DayPeople.none;
  return DayPeople(everyone: everyone, people: [for (final m in family) if (ids.contains(m.id)) m]);
}

/// A day drawn in its people's colors, at full strength: one person, their color; two or three,
/// equal side-by-side parts, one each, like the paper organizer's columns; more, the first two
/// (the day says "+N" for the rest). A day with something for everyone is ink, the way their
/// events are. Never a tint or a wash (ANTI-SLOP 3).
class DaySegments extends StatelessWidget {
  const DaySegments({super.key, required this.day});

  final DayPeople day;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (day.everyone) return ColoredBox(color: c.primary);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in day.shown) Expanded(child: ColoredBox(color: c.marker(m.marker))),
      ],
    );
  }
}

/// The text color on a day drawn by [DaySegments]: light on ink, dark ink on people's colors.
Color dayInk(DenColors c, DayPeople day) => day.everyone ? c.onPrimary : c.onMarker;
