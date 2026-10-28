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

  @override
  Route<T> createRoute(BuildContext context) => DenSheetRoute<T>(
        builder: (_) => child,
        dismissible: dismissible,
        closeLabel: closeLabel,
        settings: this,
      );
}
