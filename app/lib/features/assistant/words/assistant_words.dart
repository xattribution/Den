/// What the AI helper says on screen, and where Add sends what someone typed. Plain Dart, so the
/// rule can be tested and read on its own.
library;

import 'package:den_assistant/den_assistant.dart' show ModelException, ModelFailure, UndoIntent;

/// Where Add sends the words when the helper is on for the person: Den's own reader adds them
/// at once, or the helper answers them.
enum AddRoute { add, ask }

/// Words that start a question: "what's on Friday", "is Leo driving", "can you move soccer".
const Set<String> _questionWords = {
  'what',
  "what's",
  'whats',
  'when',
  "when's",
  'whens',
  'where',
  "where's",
  'wheres',
  'who',
  "who's",
  'whos',
  'whose',
  'which',
  'why',
  'how',
  "how's",
  'hows',
  'is',
  "isn't",
  'are',
  "aren't",
  'am',
  'was',
  'were',
  'does',
  "doesn't",
  'did',
  "didn't",
  'can',
  "can't",
  'could',
  'will',
  "won't",
  'would',
  'should',
  'shall',
  'has',
  'have',
  'any',
  'anything',
  'anyone',
  'tell',
  'show',
  'find',
  'plan',
  'summarize',
  'explain',
};

/// After "do" these make a question ("do we have practice"); "do laundry Saturday" stays an add.
const Set<String> _afterDo = {'i', 'we', 'you', 'they', 'he', 'she', 'it', 'any', 'my', 'our', 'the'};

/// Verbs that change or take back something already in Den, which Den's own reader can't do:
/// "move soccer to 6", "cancel the dentist", "give Maya 5 stars".
const Set<String> _changeWords = {
  'move',
  'reschedule',
  'postpone',
  'push',
  'cancel',
  'delete',
  'remove',
  'rename',
  'swap',
  'give',
  'undo',
  'uncheck',
  'approve',
  'decline',
  'mark',
};

/// Polite words before the real first word.
const Set<String> _leadIns = {'please', 'hey', 'ok', 'okay', 'so', 'oh', 'um', 'hi', 'den', 'and', 'also', 'then'};

List<String> _words(String text) => [
  for (final w in text.toLowerCase().replaceAll('’', "'").split(RegExp(r"[^a-z0-9']+")))
    if (w.isNotEmpty) w,
];

/// Whether [text] asks something or changes something already there, so it goes to the helper
/// even when Den's own reader finds something in it: it ends with a question mark, starts with a
/// question word, says "undo that", or one of its parts starts with a verb that changes what's
/// there ("add milk and move soccer to 6").
bool soundsLikeAsking(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  if (t.endsWith('?') || UndoIntent.matches(t)) return true;
  final parts = t.split(RegExp(r'[.;!?\n]+|,|\band\b|\bthen\b', caseSensitive: false));
  for (final (i, part) in parts.indexed) {
    final words = _words(part);
    var at = 0;
    while (at < words.length - 1 && _leadIns.contains(words[at])) {
      at++;
    }
    if (at >= words.length) continue;
    final first = words[at];
    if (_changeWords.contains(first)) return true;
    if (i > 0) continue;
    if (_questionWords.contains(first)) return true;
    if (first == 'do' && at + 1 < words.length && _afterDo.contains(words[at + 1])) return true;
  }
  return false;
}

/// The rule (DESIGN.md, "AI helper"): a question or a change goes to the helper; otherwise Den's
/// own reader takes it when it [found] something to add, and the helper when it found nothing.
AddRoute addOrAsk(String text, {required bool found}) => soundsLikeAsking(text) || !found ? AddRoute.ask : AddRoute.add;

/// How a problem with the helper is shown.
enum ProblemKind {
  /// A limit a parent set (a kid's questions a day, the month's budget): a plain line.
  limit,

  /// The helper isn't on or set up for this person: a plain line.
  refused,

  /// The hub or the company behind it couldn't answer: red words and Try again.
  down,

  /// Ask was closed while the helper worked: a plain line and Ask again.
  stopped,
}

/// Why the helper couldn't answer, in words for people.
class HelperProblem {
  const HelperProblem(this.kind, this.message);

  const HelperProblem.limit(this.message) : kind = ProblemKind.limit;
  const HelperProblem.refused(this.message) : kind = ProblemKind.refused;
  const HelperProblem.down(this.message) : kind = ProblemKind.down;
  const HelperProblem.stopped(this.message) : kind = ProblemKind.stopped;

  final ProblemKind kind;
  final String message;

  /// Whether trying again may work.
  bool get retry => kind == ProblemKind.down || kind == ProblemKind.stopped;
}

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "October", from a `YYYY-MM` or `YYYY-MM-DD` date.
String monthName(String date) {
  final month = date.length >= 7 ? int.tryParse(date.substring(5, 7)) : null;
  return month == null || month < 1 || month > 12 ? 'this month' : _months[month - 1];
}

/// A kid's questions for the day are used up.
String dailyLimitWords(int limit) => "That's $limit questions today. Ask a parent for more.";

/// The family's budget for the month is spent.
String budgetWords(String month) => "The family's AI budget is used up for ${monthName(month)}.";

/// The family turned the helper off.
const String helperOffWords = 'The AI helper is off. A parent can turn it on in Settings.';

/// The helper isn't on for [name].
String notForWords(String name) => "The AI helper isn't on for $name. A parent can turn it on in Settings.";

/// A wall display or a shared screen.
const String sharedScreenWords = "The AI helper isn't on for shared screens. Ask from your own phone.";

/// Nobody chose who runs it on the hub.
const String notSetUpWords = 'A parent needs to choose who runs the AI helper, in Settings.';

/// The family has no hub to run it through.
const String noHubWords = "The AI helper runs through the family's hub, and this family doesn't have one yet.";

/// The company behind the helper isn't answering.
String unreachableWords(String speaker) => "$speaker can't be reached right now. Try again in a few minutes.";

/// What a failed model call means for the person: the hub's refusals by their code (a kid's
/// daily limit and a busy hub are both 429), the provider being down, or the message as it came.
HelperProblem problemFor(
  ModelException? e, {
  required String fallback,
  required String speaker,
  required String name,
  required int dailyLimit,
  required String month,
}) {
  if (e == null) return HelperProblem.down(fallback);
  switch (e.code) {
    case 'daily_limit':
      return HelperProblem.limit(dailyLimitWords(dailyLimit));
    case 'budget_spent':
      return HelperProblem.limit(budgetWords(month));
    case 'assistant_off':
      return const HelperProblem.refused(helperOffWords);
    case 'not_allowed':
      return HelperProblem.refused(notForWords(name));
    case 'not_set_up':
      return const HelperProblem.refused(notSetUpWords);
    case 'busy':
      return const HelperProblem.down('The hub is busy with other questions. Try again in a moment.');
    case 'provider_unreachable':
      return HelperProblem.down(unreachableWords(speaker));
  }
  if (e.status == 402) return HelperProblem.limit(budgetWords(month));
  if (e.status == 403) return HelperProblem.refused(e.message);
  return switch (e.kind) {
    ModelFailure.busy || ModelFailure.timeout => HelperProblem.down(unreachableWords(speaker)),
    ModelFailure.network || ModelFailure.rateLimited => HelperProblem.down(e.message),
    ModelFailure.refused || ModelFailure.auth || ModelFailure.notFound => HelperProblem.refused(e.message),
    _ => HelperProblem.down(e.message),
  };
}

/// One line of what a "Do it" would change, from the fork's history entry: "Removes Feed the
/// cat".
String previewLine(String verb, String title) {
  final doing = switch (verb) {
    'added' => 'Adds',
    'removed' => 'Removes',
    'canceled' => 'Cancels',
    'restored' || 'brought back' => 'Puts back',
    'checked' || 'completed' => 'Checks off',
    'unchecked' || 'reopened' => 'Unchecks',
    'gave' => 'Gives',
    'took' => 'Takes',
    'approved' => 'Approves',
    'declined' => 'Declines',
    'swapped' => 'Swaps',
    _ => 'Changes',
  };
  return title.isEmpty ? doing : '$doing $title';
}

/// "Asking Claude", while the helper works for more than a moment.
String askingWords(String speaker) => 'Asking $speaker';

/// A turn that stopped because Ask was closed.
const String stoppedWords = 'Stopped when Ask closed. Nothing more changed.';

/// The first line of an empty conversation: "Hi Alex. What can I help with?"
String askGreeting(String? name, {required bool kid}) {
  final hi = name == null || name.isEmpty ? 'Hi.' : 'Hi $name.';
  return kid ? '$hi What do you want to know?' : '$hi What can I help with?';
}

/// What can be asked, under the greeting. Stars only while the family keeps them.
String askHelpWords({required bool kid, required bool stars}) {
  if (kid) return stars ? 'Ask about your chores, stars, lists or the calendar.' : 'Ask about your chores, lists or the calendar.';
  return 'Ask about the calendar, chores${stars ? ', stars' : ''} or lists, or ask for a change. '
      'Every change shows here with Undo.';
}

/// What the helper is, for a parent while it's off (Ask's set-up view).
const String askSetUpWords =
    'Ask about the family\'s day in your own words, or ask for a change, like "What\'s on tomorrow?" or '
    '"Add milk to Costco". Every change shows with Undo.';

/// The helper is off for the family, said to a parent who can turn it on.
const String askOffForParentWords = 'The AI helper is off. You can turn it on in Settings.';

/// Today's way into Ask.
const String askTodayLabel = 'Ask about your day';

/// Today's quiet way to set the helper up, for a parent while it's off.
const String askSetUpLabel = 'Ask in your own words';
const String askSetUpDetail = 'Set up the AI helper in Settings';

/// Puts Today's set-up line away, for this person on this device.
const String askSetUpLater = 'Not now';

/// The button to Settings, AI helper.
const String askSetUpAction = 'Set up the helper';

/// Add's way into Ask, while the helper is on.
const String askOpenLabel = 'Open Ask';
const String askOpenDetail = 'Questions and changes in your own words';

/// Starts the conversation over.
const String newChatLabel = 'New chat';
