/// Den's actions: every verb the app, the hub's REST API, MCP and the in-app assistant offer,
/// defined once as an [ActionSpec] (names, portable input and output schemas, scopes,
/// permissions, effect, confirmation, the engine methods it calls) and run by one
/// [ActionRunner] (checks, previews on a fork, confirmations, undo receipts).
///
/// Also the pieces every surface shares: [Wire] (the JSON every surface answers with), name
/// resolution ([People], [pick]) and what a caller may read ([readableSpacesFor]). Time
/// parsing lives in `package:den_actions/times.dart`.
library;

export 'src/catalog.dart';
export 'src/context.dart';
export 'src/input.dart';
export 'src/not_exposed.dart';
export 'src/privacy.dart';
export 'src/resolve.dart';
export 'src/runner.dart';
export 'src/schema.dart';
export 'src/shapes.dart' show Out;
export 'src/spec.dart';
export 'src/specs/lists.dart' show itemAlreadyOn;
export 'src/specs/points.dart' show adjustmentWarning, bigAdjustment;
export 'src/wire.dart';
