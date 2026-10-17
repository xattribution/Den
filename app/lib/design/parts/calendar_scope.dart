import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../tokens.dart';

/// Asks how far a change to a repeating event reaches: "Just this one", "This and following",
/// "All events". Returns null when the person backs out. [title] names the action and the
/// event: "Move Soccer practice", "Delete Soccer practice".
Future<EditScope?> askEditScope(BuildContext context, {required String title, bool allowOne = true}) {
  return showDialog<EditScope>(
    context: context,
    builder: (dialogContext) {
      final c = dialogContext.colors;
      Widget option(EditScope scope, String label) => Padding(
            padding: const EdgeInsets.only(bottom: Sp.s),
            child: OutlinedButton(
              onPressed: () => Navigator.of(dialogContext).pop(scope),
              child: Align(alignment: Alignment.centerLeft, child: Text(label)),
            ),
          );
      return Dialog(
        insetPadding: const EdgeInsets.all(Sp.l),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.l, Sp.l, Sp.s),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(header: true, child: Text(title, style: dialogContext.type.title(c.ink))),
                const SizedBox(height: Sp.l),
                if (allowOne) option(EditScope.one, 'Just this one'),
                option(EditScope.following, 'This and following'),
                option(EditScope.all, 'All events'),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// The design system's Undo message, shown through a messenger captured before the page that
/// made the change went away.
void showUndoOn(ScaffoldMessengerState messenger, String message, VoidCallback onUndo) {
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      action: SnackBarAction(label: 'Undo', onPressed: onUndo),
      duration: const Duration(seconds: 6),
    ),
  );
}

/// The person-facing reason a write failed, or null when it succeeded.
Future<String?> tryWrite(Future<void> Function() write) async {
  try {
    await write();
    return null;
  } on PermissionDenied catch (e) {
    return e.message;
  } on InvalidInput catch (e) {
    return e.message;
  }
}
