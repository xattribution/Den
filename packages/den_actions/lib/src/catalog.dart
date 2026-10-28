import 'runner.dart';
import 'spec.dart';
import 'specs/chores.dart';
import 'specs/events.dart';
import 'specs/lists.dart';
import 'specs/points.dart';
import 'specs/read.dart';

/// Every action Den offers, in the order `tools/list` shows them.
List<ActionSpec> allActions() => [
      ...readActions(),
      ...eventActions(),
      ...choreActions(),
      ...listActions(),
      ...pointsActions(),
    ];

/// Older action names, still callable for one release but not listed.
List<ActionAlias> actionAliases() => const [];

/// A runner over [allActions] and [actionAliases].
ActionRunner standardRunner() => ActionRunner(allActions(), aliases: actionAliases());
