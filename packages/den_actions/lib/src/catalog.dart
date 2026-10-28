import 'runner.dart';
import 'spec.dart';
import 'specs/capture.dart';
import 'specs/chores.dart';
import 'specs/events.dart';
import 'specs/family.dart';
import 'specs/lists.dart';
import 'specs/points.dart';
import 'specs/read.dart';
import 'specs/undo.dart';

/// Every action Den offers, in the order `tools/list` shows them.
List<ActionSpec> allActions() => [
      ...readActions(),
      ...eventActions(),
      ...choreActions(),
      ...listActions(),
      ...pointsActions(),
      ...captureActions(),
      ...undoActions(),
      ...familyActions(),
    ];

/// Older action names, still callable for one release but not listed: `get_today`,
/// `get_week`, `list_members`, `list_lists`, `list_rewards`, `check_step`, `check_item`,
/// `remove_item`, `clear_checked`, `create_goal` and `decide_redemption`.
List<ActionAlias> actionAliases() => [
      ...readAliases(),
      ...choreAliases(),
      ...listAliases(),
      ...pointsAliases(),
    ];

/// A runner over [allActions] and [actionAliases].
ActionRunner standardRunner() => ActionRunner(allActions(), aliases: actionAliases());
