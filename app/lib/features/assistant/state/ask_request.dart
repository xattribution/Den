import 'ask_session.dart';

/// What opens Ask (`/ask`, as the route's extra): the words from Add and whether they were said
/// out loud, or nothing ([AskRequest.open]) to show the conversation as it is. The conversation
/// itself is kept by [AskChats], so Add's words go on from the one Ask showed last, and it
/// survives Ask being drawn again as a sheet or as a panel (an iPad turning).
class AskRequest {
  AskRequest(this.words, {this.spoken = false}) : focus = false;

  /// Ask with nothing to send. [focus] puts the keyboard's focus in the field, for ⌘K.
  AskRequest.open({this.focus = false})
      : words = '',
        spoken = false;

  final String words;
  final bool spoken;

  /// Whether the field takes the keyboard's focus as Ask opens.
  final bool focus;

  /// The conversation Ask showed for this request.
  AskSession? session;

  /// Whether [words] were sent already.
  bool sent = false;
}
