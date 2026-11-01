import 'package:den_core/den_core.dart';

import '../../../app/app_state.dart';
import '../../../platform/sync/hub_client.dart' show HubException;
import '../../onboarding/state/demo_session.dart';
import '../../../platform/sync/server_setup.dart';

/// Asks the family's server how its backups stand, for a parent of the server's own family on
/// their own phone, at most once an hour, and keeps the answer on [AppState.backupProblem], where
/// Needs you and Settings read it. Anyone else, and a family that isn't the server's own, asks
/// nothing (or hears `host_family_only` once, and stops).
abstract final class ServerWatch {
  static final Map<String, int> _asked = {};
  static final Set<String> _notHost = {};

  /// Whether this device is one that may see the server's own settings: a parent's own phone in
  /// a family with a hub, outside the demo.
  static bool mayAsk(AppState app) =>
      app.den.thisDevice?.mode == DeviceMode.personal &&
      app.allowsTrust(DenAction.manageFamily) &&
      !DemoSession.active &&
      app.network?.hubDevice != null;

  /// Asks, unless asked within the hour; [source] for tests.
  static Future<void> check(AppState app, {ServerSource? source, bool force = false}) async {
    final family = app.den.familyId;
    if (family == null || _notHost.contains(family)) return;
    if (source == null && !mayAsk(app)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - (_asked[family] ?? 0) < const Duration(hours: 1).inMilliseconds) return;
    _asked[family] = now;
    try {
      final state = await (source ?? HubServerSource(app.network!)).backups();
      app.backupProblem = state.problem;
    } on HubException catch (e) {
      if (e.code == 'host_family_only' || e.code == 'not_found') _notHost.add(family);
    }
  }
}
