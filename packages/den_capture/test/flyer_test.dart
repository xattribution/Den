import 'dart:typed_data';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A parent photographs the school's fall flyer. The phone finds its text (Vision or ML Kit;
/// here, the text those return for `fixtures/flyer_ocr.txt`'s flyer), Den reads it, and the
/// family's calendar gets the book fair, picture day, science night, the early dismissal, the
/// Thanksgiving days off and the Saturday soccer clinic, each marked "from a photo".
void main() {
  final photo = CaptureFile(Uint8List.fromList(const [0xff, 0xd8, 0xff, 0xe0]), 'image/jpeg', name: 'IMG_4471.jpg');

  /// Each event's occurrences in October and November, as the family's calendar shows them.
  Map<String, List<String>> calendar(Den den, Set<String> titles) {
    final from = den.dayStart('2026-10-16');
    final to = den.dayStart('2026-12-01');
    final out = <String, List<String>>{};
    for (final o in den.occurrences(from, to)) {
      if (!titles.contains(o.title)) continue;
      out.putIfAbsent(o.title, () => []).add(
            o.allDay
                ? '${den.dateOf(o.start)} all day'
                : '${den.dateOf(o.start)} ${_clock(den, o.start)}-${_clock(den, o.end)}',
          );
    }
    return out;
  }

  Future<void> check(Den den, CaptureResult result, {required String reader, String? historyName}) async {
    final receipt = await writeDraft(den, result.draft);
    expect(receipt.failed, isEmpty);
    final titles = {for (final e in result.draft.events) e.title};
    expect({for (final t in titles) t.toLowerCase()}, {
      'fall book fair',
      'picture day',
      'family science night',
      'early dismissal',
      'no school',
      'fall soccer clinic',
    });
    final cal = {for (final e in calendar(den, titles).entries) e.key.toLowerCase(): e.value};
    expect(cal['fall book fair'], [for (final d in ['02', '03', '04', '05', '06']) '2026-11-$d 08:00-15:30']);
    expect(cal['picture day'], ['2026-10-22 all day']);
    expect(cal['family science night'], ['2026-11-12 18:00-19:30']);
    expect(cal['early dismissal'], ['2026-11-25 12:30-13:30']);
    expect(cal['no school'], ['2026-11-26 all day']);
    expect(cal['fall soccer clinic'], [
      for (final d in ['2026-10-24', '2026-10-31', '2026-11-07', '2026-11-14', '2026-11-21']) '$d 09:00-10:30',
    ]);

    final events = {for (final e in den.events) e.title.toLowerCase(): e};
    expect(events['fall book fair']!.location, 'Library');
    expect(events['fall soccer clinic']!.location, 'Riverside Park');
    expect(events['fall soccer clinic']!.rrule, 'FREQ=WEEKLY;UNTIL=20261121;BYDAY=SA');
    expect(events['no school']!.end - events['no school']!.start, greaterThan(47 * 3600000));
    // The Carters have no holiday category; school things go under School.
    expect(events['no school']!.category, isNull);
    expect(den.category(events['family science night']!.category!)!.icon, 'school');

    final history = den.history(limit: 40).where((h) => titles.contains(h.title)).toList();
    expect(history, hasLength(6));
    for (final h in history) {
      expect(h.from, CaptureOrigin(CaptureKind.photo, reader: historyName));
      expect(h.actorName, 'Alex');
    }
    expect(result.reader.id, reader);
  }

  test('on the phone alone: its text finder and Den\'s own reader', () async {
    final den = await demo();
    final ocr = FixedText(fixtureText('flyer_ocr.txt'));
    final capturer = Capturer(readers: const [RulesReader()], textFinder: ocr);
    final result = await capturer.read(CaptureInput.shared(files: [photo]), den);
    expect(ocr.calls, 1);
    expect(result.draft.origin, const CaptureOrigin(CaptureKind.photo));
    expect(result.read, contains('FALL BOOK FAIR'));
    expect(result.draft.entries.every((e) => e.ready), isTrue, reason: '${result.draft.entries.map((e) => e.issues)}');
    await check(den, result, reader: 'rules');
    await den.close();
  });

  test('with Claude: the photo itself goes, and the recorded answer becomes the same calendar', () async {
    final den = await demo();
    final ocr = FixedText(fixtureText('flyer_ocr.txt'));
    final claude = ClaudeReader(apiKey: 'sk-ant-test', client: MockClient((_) async => http.Response(fixtureText('claude_flyer.json'), 200)));
    final capturer = Capturer(readers: [claude, const RulesReader()], textFinder: ocr);
    final result = await capturer.read(CaptureInput.shared(files: [photo]), den);
    expect(ocr.calls, 0, reason: 'Claude reads the photo; nothing is recognized on the phone');
    expect(result.draft.reminders.single.text, 'Return the picture day order form');
    await check(den, result, reader: 'claude', historyName: 'Claude');
    await den.close();
  });

  test('sharing the same flyer again finds it all on the calendar already', () async {
    final den = await demo();
    final capturer = Capturer(readers: const [RulesReader()], textFinder: FixedText(fixtureText('flyer_ocr.txt')));
    await writeDraft(den, (await capturer.read(CaptureInput.shared(files: [photo]), den)).draft);
    final again = await capturer.read(CaptureInput.shared(files: [photo]), den);
    expect(again.draft.events.every((e) => e.issues.any((i) => i.kind == IssueKind.duplicate)), isTrue);
    expect((await writeDraft(den, again.draft)).isEmpty, isTrue);
    await den.close();
  });
}

String _clock(Den den, int utc) {
  final local = den.dateOf(utc);
  final midnight = den.dayStart(local);
  final minutes = (utc - midnight) ~/ 60000;
  return '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
}
