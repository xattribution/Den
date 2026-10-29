import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../capabilities.dart';
import '../web/web_app.dart';
import 'shrink_stub.dart' if (dart.library.io) 'shrink_io.dart' as shrink;

/// Why a photo couldn't be used, in words for people.
class PhotoProblem implements Exception {
  const PhotoProblem(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Where a person's photo comes from: the camera, or the photos already on the device. Each
/// answers with the photo made small on this device (the center square at 256 pixels, a JPEG of
/// at most 40 KB), ready to save, or null when the person backed out.
abstract interface class PhotoSource {
  /// A camera can take one here.
  bool get canTake;

  /// Photos already on the device can be chosen here.
  bool get canChoose;

  /// Takes a photo. In a browser, call it straight from a tap.
  Future<Uint8List?> take();

  /// Chooses a photo. In a browser, call it straight from a tap.
  Future<Uint8List?> choose();
}

/// Where this app takes photos from; tests put in their own.
abstract final class Photos {
  static PhotoSource source = DevicePhotoSource();
}

/// The device's own pickers: in a browser a file input taking `image/*` (on an iPhone or iPad it
/// offers Take Photo and Photo Library) made small by the page; on a phone the system camera
/// and photo library; on a computer the file chooser.
class DevicePhotoSource implements PhotoSource {
  DevicePhotoSource();

  static const String unreadable = 'Den couldn\'t read that picture. Try another one.';

  final _picker = ImagePicker();

  @override
  bool get canTake => Capabilities.snapPhotos || (Capabilities.web && WebApp.info.mobile);

  @override
  bool get canChoose => true;

  @override
  Future<Uint8List?> take() => _pick(camera: true);

  @override
  Future<Uint8List?> choose() => _pick(camera: false);

  Future<Uint8List?> _pick({required bool camera}) async {
    if (Capabilities.web) {
      try {
        return await WebApp.pickPhoto(camera: camera);
      } on FormatException {
        throw const PhotoProblem(unreadable);
      }
    }
    final Uint8List original;
    if (Capabilities.mobile) {
      final picked = await _picker.pickImage(
        source: camera ? ImageSource.camera : ImageSource.gallery,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 90,
      );
      if (picked == null) return null;
      original = await picked.readAsBytes();
    } else {
      const group = XTypeGroup(
        label: 'Photos',
        extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
        mimeTypes: ['image/*'],
        uniformTypeIdentifiers: ['public.image'],
      );
      final file = await openFile(acceptedTypeGroups: [group]);
      if (file == null) return null;
      original = await file.readAsBytes();
    }
    final small = await compute(shrink.shrinkPhoto, original);
    if (small == null) throw const PhotoProblem(unreadable);
    return small;
  }
}
