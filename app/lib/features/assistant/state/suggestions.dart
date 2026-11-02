import 'package:den_core/den_core.dart';

import '../../../app/family_reads.dart';
import '../../lists/lists.dart' show groceriesList;
import '../../today/today.dart' show showsTomorrow;

/// Something to ask, offered as a chip on an empty conversation.
class AskSuggestion {
  const AskSuggestion(this.words, {this.send = true, this.pick});

  final String words;

  /// A question, asked at once. A change ("Add milk to Costco") goes in the field instead, with
  /// [pick] chosen so typing replaces it: a chip never changes anything by itself.
  final bool send;

  /// The part of [words] chosen in the field ("milk"), as start and end.
  final (int, int)? pick;

  @override
  String toString() => words;
}

/// Three or four things [app]'s person might ask now, from the family's own day: what's on
/// today (tomorrow, from 5 PM, as Today looks ahead), who's driving to the next event with a ride
/// to sort out, adding to the store most of the groceries are for, and who still has chores. A
/// kid gets their own chores, their stars and their own rides; nothing that changes someone
/// else's things.
List<AskSuggestion> askSuggestions(FamilyReads app) {
  final den = app.den;
  final me = den.actor;
  final now = den.now();
  final hour = app.formats.at(now).hour;
  final ahead = showsTomorrow(hour);
  final day = ahead ? app.formats.addDays(app.today, 1) : app.today;
  final when = ahead ? 'tomorrow' : 'today';
  final kid = me?.isKid ?? false;
  final stars = den.family?.pointsEnabled ?? true;

  // The next event that day with a ride to it, the one nobody is driving first; a kid's own.
  final rides = [
    for (final o in den.today(date: day).events)
      if (o.end > now && o.rides.isNotEmpty && (!kid || o.assignees.contains(me!.id))) o,
  ]..sort((a, b) => (_driven(a) ? 1 : 0) - (_driven(b) ? 1 : 0));
  final ride = rides.firstOrNull;

  if (kid) {
    return [
      const AskSuggestion('What are my chores today?'),
      if (ride != null) AskSuggestion("Who's driving me to ${ride.title}?"),
      if (stars) const AskSuggestion('How many stars do I have?'),
      AskSuggestion("What's on $when?"),
    ].take(3).toList();
  }

  final groceries = app.canChangeItems ? groceriesList(den) : null;
  final store = groceries == null ? null : _usualStore(groceries);
  final add = groceries == null ? null : 'Add milk to ${store ?? groceries.list.title}';
  final chores = den.chores.isNotEmpty;
  return [
    AskSuggestion("What's on $when?"),
    if (ride != null) AskSuggestion("Who's driving to ${ride.title}?"),
    if (add != null) AskSuggestion(add, send: false, pick: (4, 8)),
    if (chores) const AskSuggestion('Who still has chores today?'),
    if (ride == null) const AskSuggestion("What's on this weekend?"),
  ].take(4).toList();
}

bool _driven(Occurrence o) => o.rides.every((r) => r.driver != null);

/// The store most of [list]'s open items are for, or null when none says.
String? _usualStore(ListState list) {
  final counts = <String, int>{};
  for (final item in list.items) {
    final store = item.store;
    if (item.checked || store == null || store.isEmpty) continue;
    counts[store] = (counts[store] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  return (counts.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
}
