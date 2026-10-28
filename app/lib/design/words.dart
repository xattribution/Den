/// Helpers that keep short lines from breaking badly (DESIGN.md, "Words").
library;

/// A non-breaking space.
const String nbsp = ' ';

final RegExp _numberThenWord = RegExp(r'(\d) (?=[A-Za-z%°])');
final RegExp _wordThenFinalNumber = RegExp(r'([A-Za-z]) (\d+)(?=$|[.,;!?)])');

/// Keeps numbers with their units and meridiems, and a trailing number with the word before it:
/// "3:30 PM", "40 stars", "Field 4", "October 28" never split across lines.
String keepUnits(String text) => text
    .replaceAllMapped(_numberThenWord, (m) => '${m[1]}$nbsp')
    .replaceAllMapped(_wordThenFinalNumber, (m) => '${m[1]}$nbsp${m[2]}');

/// Joins the last two words of a short line (under 60 characters) with a non-breaking space so
/// it never ends with one lonely word.
String noOrphan(String text) {
  if (text.length >= 60) return text;
  final trimmed = text.trimRight();
  final i = trimmed.lastIndexOf(' ');
  if (i <= 0) return text;
  return '${trimmed.substring(0, i)}$nbsp${trimmed.substring(i + 1)}${text.substring(trimmed.length)}';
}

/// [keepUnits] and [noOrphan] together, for titles and detail lines.
String tidy(String text) => noOrphan(keepUnits(text));
