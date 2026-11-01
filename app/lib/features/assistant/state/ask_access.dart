import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';
import 'helper_link.dart';

/// What the ways into Ask (Today, the sidebar, Add, ⌘K) offer the person using this device.
enum AskEntry {
  /// Nothing at all: a wall display or a shared screen, someone the family's rules leave out,
  /// and anyone but a parent while the helper is off.
  hidden,

  /// A parent, while the helper is off for the family or has no hub to run through: a quiet way
  /// to Settings, AI helper.
  setUp,

  /// The helper is on for this person: Ask opens.
  open,
}

/// Which [AskEntry] [app]'s person gets. [linked] says the family has a hub to run the helper
/// through ([Assistant.linkFor]). The same rule as [helperOn], plus the parent's way to set it up.
AskEntry askEntry(AppState app, {required bool linked}) {
  final me = app.den.actor;
  if (me == null || app.wall || app.den.thisDevice?.mode == DeviceMode.shared) return AskEntry.hidden;
  if (helperOn(app, linked: linked)) return AskEntry.open;
  final policy = app.den.family?.assistant ?? const AssistantPolicy();
  if (me.isParent && (!policy.enabled || !linked)) return AskEntry.setUp;
  return AskEntry.hidden;
}

/// How long after a family starts Today ends with a parent's way to set the helper up: the
/// first three weeks, while she is still finding her way around. After that it lives in
/// Settings, AI helper, and ⌘K still says what the helper does.
const Duration askSetUpWeeks = Duration(days: 21);

/// What "Not now" on Today's set-up line is kept under, for [member] ([AppState.seen]: on this
/// device, in this family).
String askSetUpSeenKey(String member) => 'ask-set-up:$member';

/// Whether Today ends with the parent's way to set the helper up ([AskEntry.setUp]): only in the
/// family's first [askSetUpWeeks] (from when it was made), and not once this person said "Not
/// now" on this device.
bool askSetUpLineShows(AppState app, {required bool linked, required int now}) {
  if (askEntry(app, linked: linked) != AskEntry.setUp) return false;
  final me = app.me;
  final family = app.den.family;
  if (me == null || family == null || app.seen(askSetUpSeenKey(me.id))) return false;
  return now - family.rec.created.millis < askSetUpWeeks.inMilliseconds;
}
