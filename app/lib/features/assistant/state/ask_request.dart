import 'ask_session.dart';

/// What opens Ask (`/ask`, as the route's extra): the words from Add, and whether they were
/// said out loud. It also holds the conversation, so the conversation lives exactly as long as
/// the route: it survives Ask being drawn again as a sheet or as a panel (an iPad turning), and
/// is forgotten when Ask closes.
class AskRequest {
  AskRequest(this.words, {this.spoken = false});

  final String words;
  final bool spoken;

  /// The conversation, once Ask has started it.
  AskSession? session;

  /// Whether [words] were sent already.
  bool sent = false;
}
