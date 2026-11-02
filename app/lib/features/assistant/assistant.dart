/// What other features use from the AI helper. Other features import this file (or a words barrel
/// beside it), never the folders behind it, and reach its pages by their routes.
///
/// Add asks whether the helper is on for the person ([helperOn]) and where the words go
/// ([addOrAsk]), then opens `/ask` with an [AskRequest]. Today, the shell's sidebar, Add and ⌘K
/// open Ask directly ([openAsk]), each showing only what [askEntry] allows the person.
library;

export 'state/ask_access.dart' show AskEntry, askEntry, askSetUpLineShows, askSetUpSeenKey, askSetUpWeeks;
export 'state/ask_request.dart' show AskRequest;
export 'state/helper_link.dart' show Assistant, AssistantScope, HelperLink, HelperStatus, helperOn;
export 'widgets/ask_entries.dart'
    show AskSetUpLine, AskTodayEntry, askAddRow, askEntryOf, askPlace, askShortcutOn, openAsk;
export 'words/assistant_words.dart' show AddRoute, addOrAsk, soundsLikeAsking;
