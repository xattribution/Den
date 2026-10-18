/// Den capture: a photo of a school flyer, a shared email or link, or "soccer every Wednesday
/// at 5 for Leo" becomes proposed events, chores, list items and reminders for the family.
///
/// A [CaptureReader] reads what was shared into one JSON shape ([CaptureWire]); [draftFrom]
/// resolves it to the family (names to members, items to lists, repeats to RRULEs);
/// [checkDraft] holds every entry to den_core's schemas and permissions before anything is
/// written; [writeDraft] adds what was chosen through the engine as the acting member, each
/// change recording where it came from. Pure Dart: the app supplies on-device readers and text
/// recognition through its platform channel.
library;

export 'src/capture.dart';
export 'src/check.dart' show checkDraft, eventSpan, reminderChore;
export 'src/context.dart';
export 'src/draft.dart';
export 'src/input.dart';
export 'src/lexicon.dart' show choreIcon, eventKind;
export 'src/reader.dart';
export 'src/readers/claude.dart';
export 'src/readers/home_model.dart';
export 'src/readers/rules.dart';
export 'src/resolve.dart' show draftFrom, ruleFor;
export 'src/wire.dart';
export 'src/write.dart';
