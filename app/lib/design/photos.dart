import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:flutter/foundation.dart';

/// People's photos, decoded once each, so a member's avatar draws their photo in its first
/// frame. The app keeps it up to date ([keep]) whenever photos or people change; an avatar whose
/// photo hasn't arrived draws the silhouette and redraws when it does ([version]).
abstract final class DenPhotos {
  static final Map<String, Uint8List> _bytes = {};

  /// Bumped whenever a photo is added or dropped.
  static final ValueNotifier<int> version = ValueNotifier(0);

  /// The encoded image for the photo record [id], or null when this device doesn't have it.
  static Uint8List? of(String? id) => id == null ? null : _bytes[id];

  /// Keeps exactly [photos]: decodes the new ones, forgets the rest. The same bytes stay the
  /// same object, so the image cache keeps their decoded frames.
  static void keep(Iterable<Photo> photos) {
    final wanted = {for (final p in photos) p.id: p};
    var changed = false;
    _bytes.removeWhere((id, _) {
      final drop = !wanted.containsKey(id);
      changed |= drop;
      return drop;
    });
    for (final p in wanted.values) {
      if (_bytes.containsKey(p.id)) continue;
      try {
        _bytes[p.id] = base64.decode(p.data);
        changed = true;
      } on FormatException {
        // Not a photo after all: the silhouette stays.
      }
    }
    if (changed) version.value++;
  }

  /// Sets one photo directly: tests and screenshots.
  @visibleForTesting
  static void put(String id, Uint8List bytes) {
    _bytes[id] = bytes;
    version.value++;
  }
}
