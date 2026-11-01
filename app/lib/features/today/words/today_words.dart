import 'package:den_core/den_core.dart';

import '../../../app/family_reads.dart';
import '../../../app/words.dart';
import '../../calendar/calendar_words.dart';

/// "Good morning" until noon, "Good afternoon" until 5 PM, "Good evening" after.
String greeting(int hour) => switch (hour) {
      >= 5 && < 12 => 'Good morning',
      >= 12 && < 17 => 'Good afternoon',
      _ => 'Good evening',
    };

/// From 5 PM, Today looks ahead to tomorrow too.
bool showsTomorrow(int hour) => hour >= 17;

/// "Leo", "Leo and Maya" (the calendar's whoWords lists with commas), or "everyone".
String _names(FamilyReads app, List<String> ids) {
  if (ids.isEmpty) return 'everyone';
  return joinWords([for (final id in ids) app.memberById(id)?.name ?? 'someone']);
}

/// The event row's second line: who it's for, and whether anyone is driving ("Leo, nobody
/// driving yet", "Leo, you're driving").
String eventWho(FamilyReads app, Occurrence occ) {
  final who = occ.forEveryone ? 'Everyone' : _names(app, occ.assignees);
  if (occ.rides.isEmpty) return who;
  final me = app.me?.id;
  if (me != null && occ.rides.any((r) => r.driver == me)) return '$who, you\'re driving';
  if (occ.rides.any((r) => r.driver == null)) return '$who, nobody driving yet';
  return who;
}

/// A sentence-case reward title inside a sentence: "movie night", but "TV time" and "iPad
/// time" stay as they are.
String inSentence(String title) {
  if (title.length < 2) return title;
  final second = title[1];
  if (second.toLowerCase() != second || title[0].toLowerCase() == title[0]) return title;
  return '${title[0].toLowerCase()}${title.substring(1)}';
}

/// "Nobody is driving Leo", "Nobody is picking up Leo", or "Nobody is driving to Swim" for an
/// event for everyone.
String rideAsk(FamilyReads app, Occurrence occ, String leg) {
  final who = occ.forEveryone ? null : _names(app, occ.assignees);
  return switch ((leg, who)) {
    ('from', null) => 'Nobody is picking up from ${occ.title}',
    ('from', final who?) => 'Nobody is picking up $who',
    (_, null) => 'Nobody is driving to ${occ.title}',
    (_, final who?) => 'Nobody is driving $who',
  };
}

/// "tomorrow" inside a sentence; a date ("Sat, Oct 17") stays as it is.
String _dayWord(String relative) => switch (relative) {
      'Today' || 'Tomorrow' || 'Yesterday' => relative.toLowerCase(),
      _ => relative,
    };

/// When the leg is: the start for the drive there, the end for the pickup.
int legTime(Occurrence occ, String leg) => leg == 'from' ? occ.end : occ.start;

/// "Soccer, 3:30 PM at Field 4", or "Soccer, tomorrow 3:30 PM" when it's not today.
String rideDetail(FamilyReads app, Occurrence occ, String leg) {
  final f = app.formats;
  final at = legTime(occ, leg);
  final day = f.localDate(at);
  final when = day == app.today ? f.time(at) : '${_dayWord(f.relative(day, app.today))} ${f.time(at)}';
  final where = occ.location.isEmpty ? '' : ' at ${occ.location}';
  return '${occ.title}, $when$where';
}

/// "You're driving Leo at 3:30 PM", "You're picking up Leo tomorrow at 5:00 PM".
String rideTaken(FamilyReads app, Occurrence occ, String leg) {
  final f = app.formats;
  final at = legTime(occ, leg);
  final day = f.localDate(at);
  final when = day == app.today ? 'at ${f.time(at)}' : '${_dayWord(f.relative(day, app.today))} at ${f.time(at)}';
  final who = occ.forEveryone ? null : _names(app, occ.assignees);
  final verb = leg == 'from' ? 'picking up' : 'driving';
  return who == null ? 'You\'re $verb for ${occ.title} $when' : 'You\'re $verb $who $when';
}

/// A late chore's second line, whose and since when: "Leo, due 7:30 AM", "Leo, not done
/// yesterday", "Anyone's, not done Wed, Oct 14".
String lateDetail(FamilyReads app, ChoreDay day) {
  final who = day.owner == null ? 'Anyone\'s' : app.memberById(day.owner)?.name ?? 'Someone';
  final due = day.chore.dueTime;
  if (day.date == app.today) return due == null ? '$who, not done yet' : '$who, due ${clockWords(due)}';
  return '$who, not done ${_dayWord(app.formats.relative(day.date, app.today))}';
}

/// "Leo and Maya have 5 late chores", for when there are more than Needs you lists one by one.
String lateSummary(FamilyReads app, List<ChoreDay> days) {
  final owners = <String>[];
  var anyone = false;
  for (final d in days) {
    if (d.owner == null) {
      anyone = true;
    } else if (!owners.contains(d.owner)) {
      owners.add(d.owner!);
    }
  }
  final names = [for (final id in owners) app.memberById(id)?.name ?? 'Someone'];
  if (names.isEmpty || anyone && names.length > 2) return '${days.length} chores are late';
  final verb = names.length == 1 ? 'has' : 'have';
  return '${joinWords(names)} $verb ${days.length} late chores';
}

/// "Packing for the lake is due tomorrow"
String listDue(FamilyReads app, ListState list) {
  final needBy = list.list.needBy!;
  final when = _dayWord(app.formats.relative(needBy, app.today));
  return '${list.list.title} is due $when';
}

/// "3 things left", "1 thing left"
String itemsLeft(int n) => '$n ${n == 1 ? 'thing' : 'things'} left';

/// The count by Needs you's heading: "2 things", "1 thing", "All done".
String needCount(int open) => open == 0 ? 'All done' : '$open ${open == 1 ? 'thing' : 'things'}';

/// Under the first few in Needs you: "2 more", which opens the rest in place.
String needsMore(int n) => '$n more';

/// What "Not now" (the × or a swipe to the left) did: back tomorrow.
const String notNowDone = 'Hidden until tomorrow';

/// A reward request declined, as one approved says it: "$5 declined for Maya".
String rewardDeclined(String title, String name) => '$title declined for $name';

/// A device turned away from Needs you: "Rosa's iPad was turned away".
String deviceTurnedAway(String device) => '$device was turned away';

/// Chores' count: "2 of 5 done".
String choresDone(List<ChoreDay> days) => '${days.where((d) => d.done).length} of ${days.length} done';

/// The Groceries link: "14 items", "1 item", "Empty".
String itemCount(int n) => n == 0 ? 'Empty' : '$n ${n == 1 ? 'item' : 'items'}';

/// "PIN" or "pattern", for how [m] signs in on shared screens.
String _secretWord(Member? m) => m?.signIn.kind == 'pattern' ? 'pattern' : 'PIN';

/// "Alex's PIN", or "your PIN" on Alex's own phone.
String _whoseSecret(FamilyReads app, String member) {
  final m = app.memberById(member);
  final whose = member == app.me?.id ? 'your' : "${m?.name ?? 'someone'}'s";
  return '$whose ${_secretWord(m)}';
}

/// What a shared screen said: "Someone tried Alex's PIN on Kitchen display 10 times".
String signInTriesSentence(FamilyReads app, SignInTries told) {
  final where = app.den.device(told.device)?.name ?? 'a shared screen';
  return 'Someone tried ${_whoseSecret(app, told.member)} on $where ${told.tries} times';
}

/// When: "Today, 7:42 AM".
String signInTriesWhen(FamilyReads app, SignInTries told) {
  final f = app.formats;
  return '${f.relative(f.localDate(told.at), app.today)}, ${f.time(told.at)}';
}
