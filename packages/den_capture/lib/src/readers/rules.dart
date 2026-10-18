import 'package:den_core/time.dart';

import '../context.dart';
import '../lexicon.dart';
import '../reader.dart';

/// Den's own reader: plain rules for the way families write dates, times, repeats, names and
/// shopping lists. Runs everywhere, offline, with nothing sent anywhere. It reads text (typed,
/// spoken, found in a photo, an email body); a model does better with messy layouts, so it
/// comes after the device's model when there is one.
class RulesReader implements CaptureReader {
  const RulesReader();

  @override
  ReaderInfo get info => const ReaderInfo(
        id: 'rules',
        name: 'Den',
        place: ReaderPlace.device,
        inputs: {ReaderInput.text},
      );

  @override
  Future<bool> available() async => true;

  @override
  Future<Map<String, Object?>> read(ReadRequest request) async => readWords(request.input.words, request.context);
}

/// [CaptureWire]'s JSON for [text], read with rules.
Map<String, Object?> readWords(String text, CaptureContext context) => _Rules(context).read(text);

const _wd = r'(?:mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|weds|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)';
const _wds = r'(?:mondays|tuesdays|wednesdays|thursdays|fridays|saturdays|sundays)';
const _mo =
    r'(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)';
/// AM or PM after a time: "5 pm", "5pm", "5 a.m.", and texting's "5p" (no space).
const _ap = r'(?:\s*(?:a\.?m\.?|p\.?m\.?)(?![a-z])|(?:a|p)(?![a-z]))';
const _codes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

RegExp _re(String pattern, {bool caseSensitive = false}) => RegExp(pattern, caseSensitive: caseSensitive);

int _weekday(String word) {
  final w = word.toLowerCase();
  const starts = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  return starts.indexWhere(w.startsWith) + 1;
}

int _month(String word) {
  const starts = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  return starts.indexWhere(word.toLowerCase().startsWith) + 1;
}

String _ymd(int y, int m, int d) =>
    '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';

String _hhmm(int minutes) => '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

/// Character ranges of a line already claimed by a date, time, repeat or name.
class _Spans {
  _Spans(this.text);
  final String text;
  final List<(int, int)> used = [];

  bool free(int s, int e) => used.every((u) => e <= u.$1 || s >= u.$2);

  /// Every match of [re] in ranges nothing has claimed, claiming them. A match that overlaps a
  /// claimed range is tried again from its next character, so "Saturday, Oct 24" with
  /// "Saturday" taken still finds "Oct 24".
  List<RegExpMatch> take(RegExp re) {
    final out = <RegExpMatch>[];
    var pos = 0;
    while (pos <= text.length) {
      final m = re.allMatches(text, pos).firstOrNull;
      if (m == null) break;
      if (m.end > m.start && free(m.start, m.end)) {
        used.add((m.start, m.end));
        out.add(m);
        pos = m.end;
      } else {
        pos = m.start + 1;
      }
    }
    return out;
  }

  /// The line with every claimed range blanked out.
  String get rest {
    final chars = text.split('');
    for (final (s, e) in used) {
      for (var i = s; i < e; i++) {
        chars[i] = ' ';
      }
    }
    return chars.join();
  }
}

class _Date {
  _Date(this.at, this.end, this.date, {this.endDate});
  final int at;
  final int end;
  final String date;
  final String? endDate;
}

class _Time {
  _Time(this.at, this.start, this.end, {this.guessed = false, this.due = false});
  final int at;
  final int start;
  final int? end;
  final bool guessed;
  final bool due;
}

/// What one line says about when, and what's left of it.
class _Scan {
  final dates = <_Date>[];
  final times = <_Time>[];
  Map<String, Object?>? repeat;
  final people = <String>[];
  String rest = '';
  bool get hasWhen => dates.isNotEmpty || repeat != null;
  bool get hasTime => times.isNotEmpty;
}

class _Rules {
  _Rules(this.c);
  final CaptureContext c;

  final events = <Map<String, Object?>>[];
  final chores = <Map<String, Object?>>[];
  final items = <Map<String, Object?>>[];
  final reminders = <Map<String, Object?>>[];
  final unclear = <String>[];

  Map<String, Object?> read(String raw) {
    final lines = _lines(raw);
    final multi = lines.where((l) => l.isNotEmpty).length > 1;
    String? loose;
    var block = <String>[];
    void flush() {
      if (block.isEmpty) return;
      final before = events.length;
      loose = _block(block, loose, multi: multi);
      if (events.length > before) loose = null;
      block = [];
    }

    for (final line in lines) {
      if (line.isEmpty) {
        flush();
      } else {
        block.add(line);
      }
    }
    flush();
    return {'events': events, 'chores': chores, 'items': items, 'reminders': reminders, 'unclear': unclear};
  }

  /// A full stop that ends a sentence, not "Nov." or "Dr.".
  static final _sentenceEnd = RegExp(
    r'(?<!\b(?:Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|Mon|Tue|Tues|Wed|Thu|Thur|Thurs|Fri|Sat|Sun|Dr|Mr|Mrs|Ms|St|Ave|Rd|Jr|Sr|vs|No))'
    r'(?<=[a-z0-9)])[.!?;]\s+(?=[A-Z0-9])',
  );

  /// Lines worth reading: mail headers and links dropped, bullets and separators tidied, a
  /// typed sentence split at its full stops.
  List<String> _lines(String raw) {
    final text = raw
        .replaceAll('\r', '')
        .replaceAll(RegExp('[   ]'), ' ')
        .replaceAll(RegExp('[–—−]'), ' - ')
        .replaceAll(RegExp(r'[·•|]'), ',')
        .replaceAll(RegExp('[‘’]'), "'");
    final out = <String>[];
    for (var line in text.split('\n')) {
      line = line.trim().replaceFirst(RegExp(r'^[,*>\-]+\s*'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (_re(r'^(from|to|cc|bcc|sent|date|reply-to):\s').hasMatch(line)) continue;
      line = line.replaceFirst(_re(r'^subject:\s*'), '');
      if (_re(r'^(https?://\S+|unsubscribe.*|view in browser.*)$').hasMatch(line)) {
        out.add('');
        continue;
      }
      if (line.isEmpty) {
        out.add('');
        continue;
      }
      for (final sentence in line.split(_sentenceEnd)) {
        out.add(sentence.trim().replaceFirst(RegExp(r'[.!?;]+$'), ''));
      }
    }
    return out;
  }

  /// Reads one block of lines (a paragraph of a flyer, or a typed sentence). [loose] is a line
  /// from just before that may title the block's first event. Returns the block's last loose
  /// line, for the next block.
  String? _block(List<String> lines, String? loose, {required bool multi}) {
    Map<String, Object?>? last;
    for (final line in lines) {
      if (_reminder(line) || _chore(line) || _shopping(line, multi: multi)) {
        last = null;
        continue;
      }
      final scan = _scan(line);
      if (scan.hasWhen) {
        final aside = [for (final m in RegExp(r'\(([^)]*)\)').allMatches(scan.rest)) ?_asideOf(m[1]!)];
        final parts = _parts(scan.rest.replaceAll(RegExp(r'\([^)]*\)'), '   '));
        var title = parts.isEmpty ? null : parts.first;
        var location = parts.length > 1 ? parts[1] : null;
        if ((title == null || _weak(title)) && loose != null) {
          title = loose;
        } else if (title != null && loose != null && _placeWord.hasMatch(title) && title.split(' ').length <= 4 && parts.length == 1) {
          location = title;
          title = loose;
        }
        if (title == null || _weak(title)) {
          unclear.add('Something on ${scan.dates.isEmpty ? 'a repeating day' : scan.dates.first.date} with no name');
          continue;
        }
        final notes = [...aside, if (parts.length > 2) parts.sublist(2).join(', ')];
        last = _event(title, scan, location: location, notes: notes.isEmpty ? null : notes.join('\n'));
        events.add(last);
        loose = null;
      } else if (scan.hasTime && last != null && last['start'] == null) {
        _setTime(last, scan.times.first);
        final parts = _parts(scan.rest);
        if (parts.isNotEmpty && last['location'] == null) last['location'] = parts.first;
      } else if (last != null) {
        if (last['location'] == null && _placeLike(line)) {
          last['location'] = _tidy(line);
        } else if (!_signOff.hasMatch(line) && ((last['notes'] as String?)?.split('\n').length ?? 0) < 3) {
          final notes = last['notes'] as String?;
          last['notes'] = notes == null ? _tidy(line) : '$notes\n${_tidy(line)}';
        }
      } else if (!multi) {
        if (_tidy(line).isNotEmpty) unclear.add(_tidy(line));
      } else {
        loose = _tidy(line);
      }
    }
    return loose;
  }

  Map<String, Object?> _event(String title, _Scan scan, {String? location, String? notes}) {
    final first = scan.dates.firstOrNull;
    var date = first?.date ?? c.today;
    var endDate = first?.endDate;
    Map<String, Object?>? repeat = scan.repeat == null ? null : Map.of(scan.repeat!);
    if (repeat != null) {
      // "Every Saturday, Oct 24 to Nov 21": the range bounds the repeat.
      final until = endDate ?? (scan.dates.length > 1 ? scan.dates[1].date : null);
      if (until != null && repeat['until'] == null) repeat['until'] = until;
      endDate = null;
    } else if (scan.dates.length > 1 && endDate == null && scan.dates[1].at - first!.end < 6) {
      endDate = scan.dates[1].date;
    }
    if (endDate != null && endDate.compareTo(date) <= 0) endDate = null;
    final out = <String, Object?>{
      'title': title,
      'date': date,
      'start': null,
      'end': null,
      'endDate': endDate,
      'repeat': repeat,
      'people': [...scan.people],
      'location': location,
      'notes': notes,
      'kind': eventKind(title),
      'remindBefore': <int>[],
    };
    if (scan.times.isNotEmpty) _setTime(out, scan.times.first);
    return out;
  }

  void _setTime(Map<String, Object?> event, _Time t) {
    event['start'] = _hhmm(t.start);
    event['end'] = t.end == null ? null : _hhmm(t.end!);
    if (t.guessed) event['_guessedTime'] = true;
  }

  // ------------------------------------------------------------------ reminders, chores, lists

  bool _reminder(String line) {
    final m = _re(
      r"^(?:please\s+)?(?:(?:remind|tell)\s+(me|us|\w+)\s+(?:to|about|that)\s+|don'?t\s+forget\s+(?:to\s+)?|remember\s+to\s+|reminder:?\s+)(.+)$",
    ).firstMatch(line);
    final due = m == null ? _re(r'^(.+?)\s+(?:is\s+|are\s+)?due\b(.*)$').firstMatch(line) : null;
    if (m == null && due == null) return false;
    final body = m != null ? m[2]! : '${due![1]} ${due[2]}';
    final scan = _scan(body);
    final who = m?[1]?.toLowerCase();
    final named = who == null || who == 'me' || who == 'us' ? null : c.person(who);
    final text = _parts(scan.rest).join(', ');
    if (text.isEmpty) return false;
    reminders.add({
      'text': m == null ? '${_tidy(due![1]!)} due' : text,
      'date': scan.dates.firstOrNull?.date ?? c.today,
      'time': scan.times.isEmpty ? null : _hhmm(scan.times.first.start),
      'people': [if (named != null) named.name else ...scan.people],
    });
    return true;
  }

  bool _chore(String line) {
    if (!looksLikeChore(line)) return false;
    final scan = _scan(line);
    if (scan.times.any((t) => t.end != null)) return false;
    final turns = _re(r'\b(take turns?|taking turns|alternat\w*|rotat\w*)\b').hasMatch(line);
    var rest = scan.rest
        .replaceAll(_re(r'\b(take turns?|taking turns|alternat\w*|rotat\w*)(\s+(doing|with|on))?\b'), ' ')
        .replaceAll(_re(r'^\s*chores?\s*:?'), ' ')
        .replaceAll(_re(r'\b(every|each)?\s*(morning|night|evening|afternoon|tonight)\b'), ' ');
    final points = _re(r'\bfor\s+(\d{1,3})\s*(?:stars?|points?)\b|\b(\d{1,3})\s*(?:stars?|points?)\b').firstMatch(rest);
    if (points != null) rest = rest.replaceRange(points.start, points.end, ' ');
    final parts = _parts(rest);
    if (parts.isEmpty) return false;
    var title = parts.first;
    final words = title.split(' ');
    final base = choreVerbs[words.first.toLowerCase()];
    if (base != null) title = [base, ...words.skip(1)].join(' ');
    final due = scan.times.firstOrNull;
    chores.add({
      'title': title,
      'people': [...scan.people],
      'takeTurns': turns && scan.people.length > 1,
      'date': scan.dates.firstOrNull?.date,
      'repeat': scan.repeat,
      'due': due == null ? null : _hhmm(due.start),
      'points': points == null ? null : int.parse(points[1] ?? points[2]!),
    });
    return true;
  }

  static final _shopCue = _re(
    r"^(?:(?:please\s+)?(?:buy|get|grab|pick\s+up|we\s+need|i\s+need|need|we're\s+out\s+of|we\s+are\s+out\s+of|out\s+of|add)\b\s*|(?:shopping|grocery|groceries|grocery\s+list|shopping\s+list)\s*:\s*)",
  );
  static final _toList = _re(r"\s+(?:to|on|for)\s+(?:the\s+|my\s+|our\s+)?([\w' ]{1,40}?)\s+list\b\s*$");
  static final _store = _re(r"\s+(?:from|at|@)\s+([A-Z][\w'&]*(?:\s+[A-Z][\w'&]*){0,2})\s*$", caseSensitive: true);
  static const _groceryWords = {
    'milk', 'eggs', 'bread', 'butter', 'cheese', 'yogurt', 'bananas', 'apples', 'coffee', 'juice', 'cereal',
    'rice', 'pasta', 'chicken', 'beef', 'onions', 'potatoes', 'tomatoes', 'lettuce', 'carrots', 'berries',
    'strawberries', 'diapers', 'wipes', 'paper towels', 'toilet paper', 'detergent', 'soap', 'shampoo',
    'toothpaste', 'flour', 'sugar', 'salt', 'oil', 'tortillas', 'avocados', 'lemons', 'grapes', 'oranges',
    'snacks', 'crackers', 'chips', 'water', 'ice cream', 'batteries',
  };

  bool _shopping(String line, {required bool multi}) {
    var text = line;
    final cue = _shopCue.firstMatch(text);
    String? listName;
    final toList = _toList.firstMatch(text);
    if (toList != null) {
      listName = toList[1]!.trim();
      text = text.substring(0, toList.start);
    }
    String? store;
    final knownStore = c.stores.isEmpty
        ? null
        : _re(r'\s+(?:from|at|@)\s+(' + c.stores.map(RegExp.escape).join('|') + r')\s*$').firstMatch(text);
    final at = knownStore ?? _store.firstMatch(text);
    if (at != null && (knownStore != null || cue != null || toList != null || text.contains(','))) {
      store = knownStore != null ? c.store(at[1]!) : at[1];
      text = text.substring(0, at.start);
    }
    if (cue != null) text = text.substring(cue.end);
    var pieces = [
      for (final p in text.split(_re(r'\s*(?:,|;|\band\b|&|\+)\s*'))) if (p.trim().isNotEmpty) p.trim(),
    ];
    if (pieces.isEmpty) return false;
    // "milk eggs bread", as speech often comes out.
    if (pieces.length == 1) {
      final words = pieces.single.toLowerCase().split(' ');
      if (words.length > 1 && words.every(_groceryWords.contains)) pieces = pieces.single.split(' ');
    }
    final scan = _scan(text);
    if (scan.hasWhen || scan.hasTime) return false;
    final known = pieces.where((p) => _groceryWords.contains(_qty(p).$2.toLowerCase())).length;
    final listy = pieces.length >= 2 && pieces.every((p) => p.split(' ').length <= 4);
    final shoppy = cue != null || toList != null || store != null || known > 0 || (listy && !multi);
    if (!shoppy) return false;
    for (final p in pieces) {
      final (qty, what) = _qty(p);
      if (what.isEmpty) continue;
      items.add({'text': what, 'qty': qty, 'store': store, 'list': listName});
    }
    return true;
  }

  static final _qtyRe = _re(
    r'^(?:(\d+(?:\.\d+)?|a\s+dozen|half\s+a\s+dozen|a\s+couple(?:\s+of)?|a\s+few|one|two|three|four|five|six|seven|eight|nine|ten|dozen)\s*'
    r'(lbs?|pounds?|oz|ounces?|kg|g|gallons?|gal|dozen|packs?|boxes|box|bags?|bottles?|cans?|cartons?|jars?|loaf|loaves|bunch(?:es)?|cases?|rolls?|x)?\b\.?\s*(?:of\s+)?)(.+)$',
  );

  /// "2 lb apples" is ("2 lb", "apples"); "milk x2" is ("2", "milk"); "a banana" is (null, "banana").
  (String?, String) _qty(String piece) {
    var p = piece.trim().replaceFirst(_re(r'^(?:some|a|an)\s+(?!dozen|couple|few)'), '');
    final times = _re(r'^(.+?)\s*(?:x\s*(\d+)|\((\d+)\))$').firstMatch(p);
    if (times != null) return (times[2] ?? times[3], times[1]!.trim());
    final m = _qtyRe.firstMatch(p);
    if (m == null || m[3]!.trim().isEmpty) return (null, p);
    return ([m[1]!.replaceAll(RegExp(r'\s+'), ' '), ?m[2]].join(' ').trim(), m[3]!.trim());
  }

  // ------------------------------------------------------------------ when

  _Scan _scan(String line) {
    final s = _Spans(line);
    final out = _Scan();
    _findRepeat(s, out);
    _findDates(s, out);
    _findTimes(s, out);
    _findPeople(s, out);
    out.rest = s.rest;
    return out;
  }

  void _findRepeat(_Spans s, _Scan out) {
    Map<String, Object?> rep(String every, {int interval = 1, List<String> days = const [], int? nth}) => {
          'every': every,
          'interval': interval,
          'days': days,
          'nth': nth,
          'monthDay': null,
          'until': null,
          'count': null,
        };
    List<String> daysIn(String text) => {
          for (final m in _re(_wd).allMatches(text))
            if (_weekday(m[0]!) > 0) _codes[_weekday(m[0]!) - 1],
        }.toList();

    final nth = s.take(_re(
      r'\bevery\s+(first|second|third|fourth|last|1st|2nd|3rd|4th)\s+(' + _wd + r')(?:\s+of\s+(?:the|each|every)\s+month)?\b',
    ));
    if (nth.isNotEmpty) {
      const order = {'first': 1, '1st': 1, 'second': 2, '2nd': 2, 'third': 3, '3rd': 3, 'fourth': 4, '4th': 4, 'last': -1};
      out.repeat = rep('month', days: daysIn(nth.first[2]!), nth: order[nth.first[1]!.toLowerCase()]);
    }
    final weekday = s.take(_re(r'\b(?:every\s+weekday|weekdays|(?:every\s+)?mon(?:day)?\s*(?:-|through|thru|to)\s*fri(?:day)?)\b'));
    if (weekday.isNotEmpty) out.repeat ??= rep('week', days: const ['MO', 'TU', 'WE', 'TH', 'FR']);
    final weekend = s.take(_re(r'\b(?:every\s+weekend|weekends)\b'));
    if (weekend.isNotEmpty) out.repeat ??= rep('week', days: const ['SA', 'SU']);
    final other = s.take(_re(r'\bevery\s+other\s+(' + _wd + r's?(?:\s*(?:,|and|&|/)\s*' + _wd + r's?)*)\b'));
    if (other.isNotEmpty) out.repeat ??= rep('week', interval: 2, days: daysIn(other.first[1]!));
    final every = s.take(_re(r'\b(?:every|each|on)\s+(' + _wd + r's?(?:\s*(?:,|and|&|/)\s*' + _wd + r's?)*)\b'));
    for (final m in every) {
      final isEvery = !m[0]!.toLowerCase().startsWith('on');
      final plural = _re(_wds).hasMatch(m[1]!);
      if (isEvery || plural) {
        out.repeat ??= rep('week', days: daysIn(m[1]!));
      } else {
        // "on Tuesday" names a day, not a repeat; give the range back to the date finder.
        s.used.removeWhere((u) => u.$1 == m.start && u.$2 == m.end);
      }
    }
    final plural = s.take(_re(r'\b(' + _wds + r'(?:\s*(?:,|and|&|/)\s*' + _wds + r')*)\b'));
    if (plural.isNotEmpty) out.repeat ??= rep('week', days: daysIn(plural.first[1]!));
    final daily = s.take(_re(
      r'\b(?:every\s*day|everyday|daily|each\s+day|every\s+(?:morning|night|evening|afternoon)|nightly|each\s+(?:morning|night|evening))\b',
    ));
    if (daily.isNotEmpty) out.repeat ??= rep('day');
    final weekly = s.take(_re(r'\b(?:every\s+(other\s+)?week|weekly|(bi-?weekly))\b'));
    if (weekly.isNotEmpty) {
      out.repeat ??= rep('week', interval: weekly.first[1] != null || weekly.first[2] != null ? 2 : 1);
    }
    if (s.take(_re(r'\b(?:every\s+month|monthly)\b')).isNotEmpty) out.repeat ??= rep('month');
    if (s.take(_re(r'\b(?:every\s+year|yearly|annually)\b')).isNotEmpty) out.repeat ??= rep('year');
    final count = s.take(_re(r'\bfor\s+(\d{1,2}|two|three|four|five|six|seven|eight|nine|ten)\s+(weeks|days|months)\b'));
    if (count.isNotEmpty && out.repeat != null) {
      const words = {'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10};
      final n = int.tryParse(count.first[1]!) ?? words[count.first[1]!.toLowerCase()]!;
      final days = (out.repeat!['days'] as List).length;
      out.repeat!['count'] = out.repeat!['every'] == 'week' && days > 1 ? n * days : n;
    }
  }

  void _findDates(_Spans s, _Scan out) {
    final found = <_Date>[];
    final y0 = int.parse(c.today.substring(0, 4));
    String? md(int month, int day, String? year) {
      if (month < 1 || day < 1 || day > 31) return null;
      var y = year == null ? y0 : int.parse(year);
      if (y < 100) y += 2000;
      var d = _ymd(y, month, day);
      if (!isLocalDate(d)) return null;
      if (year == null && daysBetween(d, c.today) > 60) d = _ymd(y + 1, month, day);
      return isLocalDate(d) ? d : null;
    }

    // "Nov 26-27", "November 26 to 27"
    for (final m in s.take(_re(r'\b(?:' + _wd + r',?\s+)?(' + _mo + r')\.?\s+(\d{1,2})(?:st|nd|rd|th)?\s*(?:-|to|through|thru)\s*(\d{1,2})(?:st|nd|rd|th)?\b(?!\s*[:/]|\s*' + _ap + r')(?:,?\s+(\d{4}))?'))) {
      final a = md(_month(m[1]!), int.parse(m[2]!), m[4]);
      final b = md(_month(m[1]!), int.parse(m[3]!), m[4]);
      if (a != null && b != null) found.add(_Date(m.start, m.end, a, endDate: b.compareTo(a) > 0 ? b : null));
    }
    for (final m in s.take(_re(r'\b(?:' + _wd + r'\.?,?\s+)?(' + _mo + r')\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b(?!\s*:)(?:,?\s+(\d{4})\b)?'))) {
      final d = md(_month(m[1]!), int.parse(m[2]!), m[3]);
      if (d != null) found.add(_Date(m.start, m.end, d));
    }
    for (final m in s.take(_re(r'\b(?:' + _wd + r'\.?,?\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(' + _mo + r')\b\.?(?:,?\s+(\d{4})\b)?'))) {
      final d = md(_month(m[2]!), int.parse(m[1]!), m[3]);
      if (d != null) found.add(_Date(m.start, m.end, d));
    }
    for (final m in s.take(_re(r'\b(\d{4})-(\d{2})-(\d{2})\b'))) {
      final d = _ymd(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
      if (isLocalDate(d)) found.add(_Date(m.start, m.end, d));
    }
    for (final m in s.take(_re(r'\b(?:' + _wd + r'\.?,?\s+)?(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b'))) {
      final d = md(int.parse(m[1]!), int.parse(m[2]!), m[3]);
      if (d != null) found.add(_Date(m.start, m.end, d));
    }
    for (final m in s.take(_re(r'\b(?:the\s+)?day\s+after\s+tomorrow\b'))) {
      found.add(_Date(m.start, m.end, addDays(c.today, 2)));
    }
    for (final m in s.take(_re(r'\b(today|tonight|this\s+(?:morning|afternoon|evening)|tomorrow|tmrw|tmr)\b'))) {
      final w = m[1]!.toLowerCase();
      found.add(_Date(m.start, m.end, w.startsWith('t') && w != 'today' && w != 'tonight' ? addDays(c.today, 1) : c.today));
    }
    for (final m in s.take(_re(r'\b(?:(this|next|coming|on)\s+)?(' + _wd + r')\b\.?'))) {
      final wd = _weekday(m[2]!);
      // "in the sun", "sat down": short forms count only written as names.
      if (wd <= 0 || const {'sun', 'sat', 'mon', 'wed'}.contains(m[2])) {
        s.used.removeWhere((u) => u.$1 == m.start && u.$2 == m.end);
        continue;
      }
      found.add(_Date(m.start, m.end, _weekdayDate(wd, m[1]?.toLowerCase())));
    }
    found.sort((a, b) => a.at.compareTo(b.at));
    // Two dates joined by "to", "through" or a dash are one span.
    for (var i = 0; i < found.length; i++) {
      final a = found[i];
      if (a.endDate != null || i + 1 >= found.length) {
        out.dates.add(a);
        continue;
      }
      final b = found[i + 1];
      final between = s.text.substring(a.end, b.at).trim().toLowerCase();
      if (const {'-', 'to', 'through', 'thru', 'until', 'till'}.contains(between)) {
        out.dates.add(_Date(a.at, b.end, a.date, endDate: b.date.compareTo(a.date) > 0 ? b.date : null));
        s.used.add((a.end, b.at));
        i++;
      } else {
        out.dates.add(a);
      }
    }
    // "until Dec 12" ends a repeat.
    if (out.repeat != null && out.dates.isNotEmpty) {
      for (final d in [...out.dates]) {
        final before = s.text.substring(0, d.at).trimRight().toLowerCase();
        if (RegExp(r'(until|till|til|through|thru|ending|ends|to)$').hasMatch(before)) {
          out.repeat!['until'] = d.endDate ?? d.date;
          out.dates.remove(d);
          final cut = RegExp(r'(until|till|til|through|thru|ending|ends|to)$').firstMatch(before)!;
          s.used.add((cut.start, cut.end));
        }
      }
    }
  }

  /// The [weekday] (1 Monday) meant by "Tuesday" (the next one, today included), "this
  /// Tuesday" (the same) or "next Tuesday" (the one in next week).
  String _weekdayDate(int weekday, String? qualifier) {
    if (qualifier == 'next') {
      final nextWeek = addDays(startOfWeek(c.today, c.weekStart), 7);
      for (var i = 0; i < 7; i++) {
        final d = addDays(nextWeek, i);
        if (weekdayOf(d) == weekday) return d;
      }
    }
    return addDays(c.today, (weekday - weekdayOf(c.today)) % 7);
  }

  void _findTimes(_Spans s, _Scan out) {
    final evening = _re(r'\b(tonight|evening|dinner|night)\b').hasMatch(s.text);
    final morning = _re(r'\b(morning|breakfast)\b').hasMatch(s.text);
    int? half(String? text) {
      if (text == null) return null;
      return text.trim().toLowerCase().startsWith('p') ? 1 : 0;
    }

    int clock(int h, int m, int? meridiem) {
      if (meridiem == null) return h * 60 + m;
      final hour = h % 12 + (meridiem == 1 ? 12 : 0);
      return hour * 60 + m;
    }

    (int, bool) guess(int h, int m) {
      if (h >= 13 || h == 0) return (h * 60 + m, false);
      if (evening && h < 12) return ((h + 12) * 60 + m, false);
      if (morning) return (h * 60 + m, false);
      if (h == 12) return (12 * 60 + m, false);
      return (h <= 6 ? (h + 12) * 60 + m : h * 60 + m, true);
    }

    for (final m in s.take(_re(r'\b(noon|midday|midnight)\b'))) {
      out.times.add(_Time(m.start, m[1]!.toLowerCase() == 'midnight' ? 0 : 12 * 60, null));
    }
    // "6:00-7:30 PM", "9 - 10:30 am", "from 3 to 4:30", "11-1pm"
    for (final m in s.take(_re(
      r'(?:\b(from|at|@)\s+)?\b(\d{1,2})(?::(\d{2}))?(' + _ap + r')?\s*(?:-|to|until|till)\s*(\d{1,2})(?::(\d{2}))?(' + _ap + r')?',
    ))) {
      final cue = m[1] != null || m[3] != null || m[6] != null || m[4] != null || m[7] != null;
      final h1 = int.parse(m[2]!), h2 = int.parse(m[5]!);
      if (!cue || h1 > 23 || h2 > 23) {
        s.used.removeWhere((u) => u.$1 == m.start && u.$2 == m.end);
        continue;
      }
      final m1 = int.parse(m[3] ?? '0'), m2 = int.parse(m[6] ?? '0');
      var a = half(m[4]);
      final b = half(m[7]);
      int end;
      int start;
      var guessed = false;
      if (b != null) {
        end = clock(h2, m2, b);
        a ??= clock(h1, m1, b) <= end ? b : 1 - b;
        start = clock(h1, m1, a);
      } else if (a != null) {
        start = clock(h1, m1, a);
        end = clock(h2, m2, a);
        if (end <= start) end = clock(h2, m2, 1 - a);
      } else {
        (start, guessed) = guess(h1, m1);
        end = h2 * 60 + m2;
        while (end <= start && end < 24 * 60 - 12 * 60) {
          end += 12 * 60;
        }
      }
      out.times.add(_Time(m.start, start, end > start ? end : null, guessed: guessed));
    }
    for (final m in s.take(_re(
      r'(?:\b(by|before|at|@|around|from|starts?|starting|begins?)\s+)?\b(\d{1,2})(?::(\d{2}))?(' + _ap + r')',
    ))) {
      final h = int.parse(m[2]!);
      if (h < 1 || h > 12) continue;
      out.times.add(_Time(m.start, clock(h, int.parse(m[3] ?? '0'), half(m[4])), null, due: _due(m[1])));
    }
    for (final m in s.take(_re(r'(?:\b(by|before|at|@|around|from)\s+)?\b([01]?\d|2[0-3]):([0-5]\d)\b'))) {
      final h = int.parse(m[2]!), min = int.parse(m[3]!);
      final (at, guessed) = guess(h, min);
      out.times.add(_Time(m.start, at, null, guessed: guessed, due: _due(m[1])));
    }
    for (final m in s.take(_re(r'\b(at|@|by|before|around)\s+(\d{1,2})\b(?!\s*(?:/|-|\.\d|st|nd|rd|th|lb|oz|%))'))) {
      final h = int.parse(m[2]!);
      if (h < 1 || h > 23) continue;
      final (at, guessed) = guess(h, 0);
      out.times.add(_Time(m.start, at, null, guessed: guessed, due: _due(m[1])));
    }
    out.times.sort((a, b) => a.at.compareTo(b.at));
  }

  static bool _due(String? cue) => cue != null && (cue.toLowerCase() == 'by' || cue.toLowerCase() == 'before');

  void _findPeople(_Spans s, _Scan out) {
    final names = <String, String>{};
    for (final p in c.people) {
      final full = p.name.toLowerCase();
      names[full] = p.name;
      final first = full.split(' ').first;
      if (c.people.where((q) => q.name.toLowerCase().split(' ').first == first).length == 1) names[first] = p.name;
    }
    final sorted = names.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final key in sorted) {
      for (final _ in s.take(_re(r"(?:\b(?:for|with|and|&)\s+)?\b" + RegExp.escape(key) + r"(?:'s)?\b(?:\s+(?:has|have|is|will))?"))) {
        final name = names[key]!;
        if (!out.people.contains(name)) out.people.add(name);
      }
    }
    final actor = c.actor;
    if (actor != null) {
      final me = s.take(_re(r"\b(?:for\s+me|i\s+have|i've\s+got|i\s+got|i'm\s+going\s+to|i\s+need\s+to\s+go\s+to)\b"));
      if (me.isNotEmpty && !out.people.contains(actor.name)) out.people.add(actor.name);
    }
  }

  // ------------------------------------------------------------------ words

  static final _filler = _re(
    r"^(?:(?:and|or|the|our|my|your|their|on|at|for|from|with|to|is|are|has|have|will\s+be|starting|starts|begins|until|till|every|each|this|next|date|time|when|where|a|an|of|in|by)\b\s*)+|(?:\s*\b(?:and|or|the|on|at|for|from|with|to|is|are|starting|starts|begins|until|till|every|each|this|next|of|in|by)\b)+$",
  );

  /// What's left of a line as its parts: title, place, notes.
  List<String> _parts(String rest) {
    final out = <String>[];
    final at = _re(r'\s+(?:at|@|in)\s+(?=[A-Z0-9])', caseSensitive: true);
    for (var part in rest.split(RegExp(r'\s+-\s+|\s*[,:;()\[\]]\s*|\s{3,}'))) {
      final atMatch = at.firstMatch(part);
      final pieces = atMatch == null ? [part] : [part.substring(0, atMatch.start), part.substring(atMatch.end)];
      for (part in pieces) {
        final t = _tidy(part);
        if (t.replaceAll(RegExp(r'[^A-Za-z]'), '').length >= 2) out.add(t);
      }
    }
    return out;
  }

  /// What a parenthesis said, when it says something.
  String? _asideOf(String text) {
    final t = _tidy(text);
    return t.replaceAll(RegExp(r'[^A-Za-z]'), '').length >= 2 ? t : null;
  }

  String _tidy(String text) {
    var t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    for (var i = 0; i < 3; i++) {
      t = t.replaceAll(_filler, '').trim();
      t = t.replaceAll(RegExp(r'^[\s,.;:\-–—!]+|[\s,;:\-–—]+$'), '').trim();
    }
    return t;
  }

  /// Words that don't make a title on their own.
  static bool _weak(String title) =>
      _re(r'^(date|dates|time|times|when|where|location|place|details?|info|schedule|what|from|to|and|all day|starts?|ends?)$')
          .hasMatch(title.trim());

  static final _placeWord = _re(
    r'\b(park|field|gym|library|cafeteria|auditorium|room|hall|center|centre|church|pool|stadium|arena|street|st|ave|avenue|road|rd|campus|court|studio|ymca|rink)\b',
  );
  static final _signOff = _re(r'^(thanks|thank you|regards|best|sincerely|cheers|sent from|love)\b');

  /// A short line that names a place: "Gym", "Riverside Park, Field 4", "Room 12".
  static bool _placeLike(String line) {
    final t = line.trim();
    if (t.isEmpty || t.split(' ').length > 6 || t.endsWith('!') || t.endsWith('?')) return false;
    if (_re(r'^(location|where|place)\s*:').hasMatch(t) || _placeWord.hasMatch(t)) return true;
    final words = t.split(' ');
    return words.length <= 3 && words.every((w) => w.isNotEmpty && w[0].toUpperCase() == w[0] && RegExp('[A-Za-z]').hasMatch(w[0]));
  }
}
