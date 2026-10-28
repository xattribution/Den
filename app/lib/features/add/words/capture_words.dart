import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';

import '../../../app/family_reads.dart';
import '../../calendar/calendar_words.dart';

/// "from a photo", "from an email", "said out loud": where a change came from, as History says it.
String originWords(CaptureKind kind) => switch (kind) {
      CaptureKind.photo => 'from a photo',
      CaptureKind.screenshot => 'from a screenshot',
      CaptureKind.pdf => 'from a PDF',
      CaptureKind.email => 'from an email',
      CaptureKind.message => 'from a message',
      CaptureKind.link => 'from a web page',
      CaptureKind.voice => 'said out loud',
      CaptureKind.typed => 'typed into Add',
      CaptureKind.assistant => 'from the assistant',
    };

/// "from a photo, read by Claude"; "from the assistant (Claude)".
String sourceWords(CaptureOrigin origin) => origin.kind == CaptureKind.assistant
    ? [originWords(origin.kind), if (origin.reader != null) '(${origin.reader})'].join(' ')
    : [originWords(origin.kind), if (origin.reader != null) 'read by ${origin.reader}'].join(', ');

/// The review page's heading: "From a photo".
String captureTitle(CaptureKind kind) => switch (kind) {
      CaptureKind.voice => 'From what you said',
      CaptureKind.typed => 'From what you typed',
      _ => () {
          final w = originWords(kind);
          return '${w[0].toUpperCase()}${w.substring(1)}';
        }(),
    };

/// "Reading the photo", while a reader works.
String readingWords(CaptureKind kind) => switch (kind) {
      CaptureKind.photo => 'Reading the photo',
      CaptureKind.screenshot => 'Reading the screenshot',
      CaptureKind.pdf => 'Reading the PDF',
      CaptureKind.email => 'Reading the email',
      CaptureKind.message => 'Reading the message',
      CaptureKind.link => 'Reading the page',
      CaptureKind.voice || CaptureKind.typed || CaptureKind.assistant => 'Reading what you wrote',
    };

/// "Read on this phone", "Read by Claude".
String readerWords(ReaderInfo reader) => switch (reader.place) {
      ReaderPlace.device => reader.historyName == null ? 'Read on this device' : 'Read on this device by ${reader.historyName}',
      ReaderPlace.home => 'Read by the home model',
      ReaderPlace.provider => 'Read by ${reader.name}',
    };

/// When an event happens, in words: "Wed, Oct 21 · 5:00 PM to 6:00 PM · Every Wednesday".
String eventWhen(FamilyReads app, DraftEvent e) {
  final f = app.formats;
  final day = f.shortWithYear(e.date, relativeTo: app.today);
  final parts = <String>[
    if (e.endDate != null) '$day to ${f.shortWithYear(e.endDate!, relativeTo: app.today)}' else day,
    if (e.allDay)
      'All day'
    else
      [f.clock(f.parseHhmm(e.start)!), if (e.end != null) f.clock(f.parseHhmm(e.end)!)].join(' to '),
    if (e.rrule != null) ?describeRrule(e.rrule, f, startDate: e.date, weekStart: app.den.family?.weekStart ?? 0),
  ];
  return parts.join(' · ');
}

/// "Leo · Every Thursday · by 7:00 PM", "Anyone · Sat, Oct 24".
String choreWhen(FamilyReads app, DraftChore c) {
  final f = app.formats;
  return [
    ownerWords(app, c.owner),
    if (c.rrule == null)
      f.shortWithYear(c.date, relativeTo: app.today)
    else
      ?describeRrule(c.rrule, f, startDate: c.date, weekStart: app.den.family?.weekStart ?? 0),
    if (c.dueTime != null) 'by ${f.clock(f.parseHhmm(c.dueTime)!)}',
    if (c.points > 0) '${c.points} ${c.points == 1 ? 'star' : 'stars'}',
  ].join(' · ');
}

String ownerWords(FamilyReads app, ChoreOwner owner) => switch (owner) {
      OwnerMember(:final id) => app.memberById(id)?.name ?? 'Someone',
      OwnerRotation(:final ids) => '${joinWords([for (final id in ids) app.memberById(id)?.name ?? 'someone'])} take turns',
      OwnerAnyone() => 'Anyone',
    };

/// "Sat, Oct 17 · 9:00 AM · Alex".
String reminderWhen(FamilyReads app, DraftReminder r) {
  final f = app.formats;
  return [
    f.shortWithYear(r.date, relativeTo: app.today),
    if (r.time != null) f.clock(f.parseHhmm(r.time)!),
    if (r.person != null) app.memberById(r.person)?.name ?? 'Someone',
  ].join(' · ');
}

/// "2 lb · Costco".
String itemDetail(DraftItem i) => [?i.qty, ?i.store].join(' · ');

/// The list an item goes on, by name, and whether Den will make it.
(String, bool) itemList(FamilyReads app, DraftItem i) {
  if (i.listId != null) return (app.den.list(i.listId!)?.list.title ?? 'A list', false);
  return (i.newList!.title, true);
}

/// The people a draft entry is for, for its marker bar.
List<String> entryPeople(DraftEntry e) => switch (e) {
      DraftEvent() => e.people,
      DraftChore(:final owner) => switch (owner) {
          OwnerMember(:final id) => [id],
          OwnerRotation(:final ids) => ids,
          OwnerAnyone() => const [],
        },
      DraftReminder() => [?e.person],
      DraftItem() => const [],
    };

/// "Add 5 things", "Add 1 thing".
String addWords(int n) => n == 1 ? 'Add 1 thing' : 'Add $n things';
