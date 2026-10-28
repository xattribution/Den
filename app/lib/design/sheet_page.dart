import 'package:flutter/widgets.dart';

import 'sheet.dart';

/// A [DenSheetRoute] as a router page, so a route (`/event/new`) can open as a sheet: from the
/// bottom on phones, a centered form sheet on iPad, on the sheet spring, dragged down to close.
/// Give it the route's page key.
///
/// ```dart
/// GoRoute(path: '/event/new', pageBuilder: (context, s) => DenSheetPage(key: s.pageKey, child: const EventEditorSheet()))
/// ```
class DenSheetPage<T> extends Page<T> {
  const DenSheetPage({super.key, required this.child, this.dismissible = true, this.closeLabel = 'Close', super.name});

  final Widget child;
  final bool dismissible;
  final String closeLabel;

  /// The sheet shows the page it was last given, so a route that updates in place (new query
  /// parameters) updates the sheet too.
  @override
  Route<T> createRoute(BuildContext context) {
    late final DenSheetRoute<T> route;
    route = DenSheetRoute<T>(
      builder: (_) => (route.settings as DenSheetPage<T>).child,
      dismissible: dismissible,
      closeLabel: closeLabel,
      settings: this,
    );
    return route;
  }
}
