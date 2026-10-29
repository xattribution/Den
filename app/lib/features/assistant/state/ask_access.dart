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
