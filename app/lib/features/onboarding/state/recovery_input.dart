import 'package:den_net/den_net.dart' show RecoveryWords, normalizeCode;

/// How far someone has got typing on "I lost my phone".
enum RecoveryTyped {
  /// Nothing yet.
  empty,

  /// Some words, not yet a whole set.
  partial,

  /// Twelve words, but one is wrong: the checksum doesn't add up.
  wrongWord,

  /// Their own twelve recovery words.
  twelve,

  /// Four words (or the link) from whoever runs the hub.
  four,
}

/// Reads what was typed or pasted: the 12 words, the 4 from the hub (or its whole link), or how
/// many known words so far.
({RecoveryTyped kind, int count}) readRecoveryInput(String text) {
  var rest = text.trim();
  final at = rest.indexOf('#/recover/');
  if (at >= 0) rest = Uri.decodeComponent(rest.substring(at + '#/recover/'.length));
  if (rest.isEmpty) return (kind: RecoveryTyped.empty, count: 0);
  if (RecoveryWords.parse(rest) != null) return (kind: RecoveryTyped.twelve, count: RecoveryWords.count);
  final count = RecoveryWords.countIn(rest);
  if (count == 4 && normalizeCode(rest) != null) return (kind: RecoveryTyped.four, count: 4);
  final typed = [
    for (final t in rest.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
      if (t.isNotEmpty && !RegExp(r'^\d+$').hasMatch(t)) t,
  ].length;
  if (typed >= RecoveryWords.count) return (kind: RecoveryTyped.wrongWord, count: count);
  return (kind: RecoveryTyped.partial, count: count);
}
