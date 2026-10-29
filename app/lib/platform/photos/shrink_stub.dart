import 'dart:typed_data';

/// In a browser the page makes photos small with a canvas (web/den_web.js), so the app
/// carries no image codec there.
Uint8List? shrinkPhoto(Uint8List bytes) => null;
