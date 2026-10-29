/// What the family's parental controls add to the engine's answers: a person told that their
/// privacy changed. See ARCHITECTURE.md, "Parental controls".
library;

/// A change to whether parents see someone's "Just me" items ([Den.privacyChange]).
class PrivacyChange {
  const PrivacyChange({
    required this.change,
    required this.member,
    required this.by,
    required this.at,
    required this.parentsSee,
  });

  /// The change's id: a device remembers which one its person has seen.
  final String change;

  /// Whose privacy it is.
  final String member;

  /// Who changed it (a parent), or null.
  final String? by;

  /// When, in UTC milliseconds.
  final int at;

  /// Whether parents see that person's "Just me" items now.
  final bool parentsSee;
}
