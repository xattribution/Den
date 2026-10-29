import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// [bytes] (a JPEG, PNG, WebP, GIF...) as a person's photo: turned upright, its center square
/// at 256 pixels, as a JPEG of at most 40 KB. Null when it can't be read. Runs off the UI
/// thread (`compute`).
Uint8List? shrinkPhoto(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final upright = img.bakeOrientation(decoded);
  final square = img.copyResizeCropSquare(upright, size: 256, interpolation: img.Interpolation.average, antialias: true);
  for (var quality = 85; quality >= 35; quality -= 10) {
    final jpeg = img.encodeJpg(square, quality: quality);
    if (jpeg.length <= 40 * 1024) return jpeg;
  }
  return null;
}
