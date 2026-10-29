/// What other features use from the AI helper. Other features import this file (or a words
/// barrel beside it), never the folders behind it, and reach its pages by their routes.
///
/// Add asks whether the helper is on for the person ([helperOn]) and where the words go
/// ([addOrAsk]), then opens `/ask` with an [AskRequest].
library;

export 'state/ask_request.dart' show AskRequest;
export 'state/helper_link.dart' show Assistant, AssistantScope, HelperLink, HelperStatus, helperOn;
export 'words/assistant_words.dart' show AddRoute, addOrAsk, soundsLikeAsking;
