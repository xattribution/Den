/// What other features use from today. Other features import this file (or a words barrel
/// beside it), never the folders behind it, and reach its pages by their routes.
///
/// The AI helper reads today's plan from the same view Today shows, and looks ahead to tomorrow
/// from the same hour.
library;

export 'state/needs_you.dart' show NeedsModel;
export 'state/today_model.dart' show TodayModel, todayReads;
export 'words/today_words.dart' show showsTomorrow;
