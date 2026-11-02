/// How Den compares the names people give things: searching, and telling whether a new list,
/// chore, reward or item is one the family already has.
library;

final RegExp _split = RegExp(r"[\s,.;:!?()\[\]{}/\\]+");

/// [text] as words to search with: lowercased, split at spaces and punctuation, a possessive
/// "'s" dropped ("Jimmy's" is "jimmy").
List<String> searchWords(String text) => [
      for (final w in text.toLowerCase().split(_split))
        if (w.isNotEmpty) w.endsWith("'s") || w.endsWith('’s') ? w.substring(0, w.length - 2) : w,
    ]..removeWhere((w) => w.isEmpty);

/// [name] as Den compares names: trimmed, lowercased, with runs of spaces as one.
String nameKey(String name) => name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Whether two names are the same to people: "Milk", "milk" and "Milk " are.
bool sameName(String a, String b) => nameKey(a) == nameKey(b);

/// Whether [word] is a typo of [other]: for a word of four letters or more, one letter off
/// (missing, extra, changed or two swapped), two for eight letters or more.
bool nearlySame(String word, String other) {
  if (word.length < 4 || word == other) return word == other;
  final most = word.length >= 8 ? 2 : 1;
  if ((word.length - other.length).abs() > most) return false;
  return _distance(word, other, most) <= most;
}

/// Damerau-Levenshtein distance (optimal string alignment), giving up past [most].
int _distance(String a, String b, int most) {
  final n = a.length, m = b.length;
  var before = List<int>.filled(m + 1, 0);
  var row = List<int>.generate(m + 1, (j) => j);
  var next = List<int>.filled(m + 1, 0);
  for (var i = 1; i <= n; i++) {
    next[0] = i;
    var best = next[0];
    for (var j = 1; j <= m; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var d = row[j] + 1;
      if (next[j - 1] + 1 < d) d = next[j - 1] + 1;
      if (row[j - 1] + cost < d) d = row[j - 1] + cost;
      if (i > 1 && j > 1 && a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) && a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
        if (before[j - 2] + 1 < d) d = before[j - 2] + 1;
      }
      next[j] = d;
      if (d < best) best = d;
    }
    if (best > most) return most + 1;
    final t = before;
    before = row;
    row = next;
    next = t;
  }
  return row[m];
}
