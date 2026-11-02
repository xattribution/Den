import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../../app/actions.dart';
import '../../../app/den_scope.dart';

/// Someone's picture: one from the pack or their initial (the `set_picture` action), or a photo.
/// A parent changes anyone's; others their own, a kid when a parent allows it.
class PictureActions {
  const PictureActions(this._actions);

  final AppActions _actions;

  Future<ActionResult> setPicture(String member, String picture) =>
      _actions.run('set_picture', {'person': member, 'picture': picture});

  /// [bytes] is the photo already made small on this device. No action offers this on purpose
  /// (an AI connection or the assistant can't add a photo), so it goes to the engine here, with
  /// a receipt for Undo.
  Future<Receipt?> setPhoto(String member, Uint8List bytes) =>
      _actions.record('Changed the photo', () async => _actions.den.setPhoto(member, bytes));
}

extension PictureActionsOf on BuildContext {
  /// Pictures and photos. Reading them never rebuilds.
  PictureActions get pictureActions => PictureActions(actions);
}
