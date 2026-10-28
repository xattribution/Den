/// Recognizes "undo that" and its everyday variants, so the app can undo the last receipt at once
/// without a model call.
abstract final class UndoIntent {
  static final RegExp _pattern = RegExp(
    r'^\s*(?:(?:oops|oh no|no|wait|please)[,!.]*\s+)*'
    r'(?:undo|take\s+(?:that|it)\s+back|reverse\s+(?:that|it)|cancel\s+that|put\s+it\s+back)'
    r'(?:\s+(?:that|it|this|the\s+last\s+(?:one|thing|change)))?'
    r'(?:[,]?\s+please)?\s*[.!]*\s*$',
    caseSensitive: false,
  );

  /// Whether [text] only asks to undo the last change.
  static bool matches(String text) => _pattern.hasMatch(text);
}
