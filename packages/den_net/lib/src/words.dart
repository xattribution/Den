import 'util.dart';
import 'wordlist.dart';

/// The three matching words both screens show for a session, derived from its transcript hash.
///
/// A relay that substituted its own keys runs two sessions with two different transcripts, so
/// the two screens would show different words (a 1 in 2^33 chance of a match).
Future<List<String>> matchingWords(List<int> transcriptHash, {int count = 3}) async {
  final digest = await sha256(concatBytes([utf8Bytes('den/sas/v1'), transcriptHash]));
  return _wordsFromBits(digest, count);
}

List<String> _wordsFromBits(List<int> bytes, int count) {
  final words = <String>[];
  var buffer = 0;
  var bits = 0;
  var i = 0;
  while (words.length < count) {
    while (bits < 11) {
      buffer = ((buffer << 8) | bytes[i++]) & 0xfffff;
      bits += 8;
    }
    words.add(wordList[(buffer >> (bits - 11)) & 0x7ff]);
    bits -= 11;
  }
  return words;
}

/// Index of [word] in the word list, accepting the unique four-letter prefix; -1 if unknown.
int wordIndex(String word) {
  final w = word.trim().toLowerCase();
  if (w.isEmpty) return -1;
  var lo = 0;
  var hi = wordList.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final cmp = wordList[mid].compareTo(w);
    if (cmp == 0) return mid;
    if (cmp < 0) {
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (w.length >= 4) {
    final prefix = w.substring(0, 4);
    for (var j = 0; j < wordList.length; j++) {
      if (wordList[j].startsWith(prefix) && (w.length == 4 || wordList[j] == w)) return j;
    }
  }
  return -1;
}
