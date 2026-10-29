/// What other features use from shared screens. Other features import this file (or a words barrel
/// beside it), never the folders behind it, and reach its pages by their routes.
library;

export 'state/display.dart';
export 'state/kids.dart';
// The AI helper reads its answers aloud to a kid the way the kids' app reads chores.
export 'widgets/kid_parts.dart' show speak;
