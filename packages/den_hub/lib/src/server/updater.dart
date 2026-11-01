/// Updating Den on the server from a parent's phone: the server's updater (outside the hub: a
/// systemd timer on the host, from the install's packaging) says which version runs and which is
/// available, and the hub asks it to update. The hub talks to it only through [ServerUpdater].
///
/// [FileUpdater], the contract with the packaging (docs/install-technical.md), in the data
/// directory's `hub/`:
///
/// - the updater writes `update.json`, one line, owner-only: `{"state": "checking" | "updating" |
///   "updated" | "up-to-date" | "available" | "rolled-back" | "failed", "message": "Updated to
///   v1.2.0", "current": "v1.2.0", "available": "v1.3.0", "previous": ..., "channel": "stable",
///   "policy": "auto" | "manual", "checked": "...Z", "updated": "...Z"}`;
/// - the hub writes `update-request` (any content: it says when, and who asked) when a parent
///   taps Update now; a systemd path unit starts the update within seconds and removes the file,
///   and the hub restarts on the new version (the app reconnects).
///
/// No `update.json` (a dev build, an install without the updater): Settings shows no update row.
library;

import 'dart:convert';
import 'dart:io';

/// The updater's status file in `hub/`.
const String updateStatusFile = 'update.json';

/// The file the hub writes in `hub/` to ask for an update.
const String updateRequestFile = 'update-request';

/// The file in `hub/` that makes the nightly run only report what is available.
const String updatePolicyFile = 'update-policy';

/// What the updater says.
class UpdateInfo {
  /// The versions, and how an update stands.
  const UpdateInfo({required this.current, this.available, this.checked, this.state = 'idle', this.message, this.asked = false});

  /// The version running (`v1.2.0`).
  final String current;

  /// A newer one, or null.
  final String? available;

  /// When the updater last looked, as it wrote it.
  final String? checked;

  /// `idle`, `updating` or `failed`, from the updater's own states.
  final String state;

  /// What the updater said in plain words, for a failure.
  final String? message;

  /// Whether "Update now" was tapped and the updater hasn't taken it yet.
  final bool asked;

  /// Whether there is something newer.
  bool get newer => available != null && available!.isNotEmpty && available != current;

  /// As answers say it.
  Map<String, Object?> toJson() => {
        'current': current,
        if (newer) 'available': available,
        'checked': ?checked,
        'state': asked && state == 'idle' ? 'updating' : state,
        if (state == 'failed' && message != null) 'message': message,
      };
}

/// The server's updater, as the hub sees it.
abstract interface class ServerUpdater {
  /// What it says, or null when there is no updater.
  Future<UpdateInfo?> info();

  /// Asks it to update now, as [by] did.
  Future<void> updateNow({String? by});
}

/// [ServerUpdater] through files in [dir], the data directory's `hub/` (see the library's
/// comment).
class FileUpdater implements ServerUpdater {
  /// The updater whose files are in [dir].
  const FileUpdater(this.dir);

  /// `<data>/hub`.
  final String dir;

  File get _status => File([dir, updateStatusFile].join(Platform.pathSeparator));
  File get _request => File([dir, updateRequestFile].join(Platform.pathSeparator));

  @override
  Future<UpdateInfo?> info() async {
    if (!_status.existsSync()) return null;
    try {
      final j = jsonDecode(await _status.readAsString());
      if (j is! Map || j['current'] is! String) return null;
      final state = switch (j['state']) {
        'updating' => 'updating',
        'failed' || 'rolled-back' => 'failed',
        _ => 'idle',
      };
      return UpdateInfo(
        current: j['current'] as String,
        available: j['available'] is String ? j['available'] as String : null,
        checked: j['checked'] is String ? j['checked'] as String : null,
        state: state,
        message: j['message'] is String ? j['message'] as String : null,
        asked: _request.existsSync(),
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> updateNow({String? by}) async {
    await Directory(dir).create(recursive: true);
    final temp = File('${_request.path}.tmp');
    await temp.writeAsString(jsonEncode({'at': DateTime.now().toUtc().millisecondsSinceEpoch, 'by': ?by}), flush: true);
    await temp.rename(_request.path);
  }
}
