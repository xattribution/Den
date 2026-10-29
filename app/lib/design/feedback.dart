import 'package:flutter/material.dart';

/// Shows a message with Undo, the way reversible actions confirm themselves.
void showUndo(BuildContext context, String message, VoidCallback onUndo) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      action: SnackBarAction(label: 'Undo', onPressed: onUndo),
      duration: const Duration(seconds: 6),
    ),
  );
}

/// Shows a plain message (errors name the cause and the way out).
void showNote(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 5)));
}
