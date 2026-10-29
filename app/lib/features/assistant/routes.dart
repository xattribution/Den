import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../app/side_panel.dart' show panelBreakpoint;
import '../../design/sheet_page.dart';
import 'screens/ask_screen.dart';
import 'state/ask_request.dart';
import 'widgets/ask_panel.dart';

/// Ask, the AI helper's conversation: `/ask`, with an [AskRequest] as the route's extra (Add's
/// words, or [AskRequest.open] from Today, the sidebar, Add or ⌘K). A sheet on phones; from
/// 840 pt a panel at the right edge, with the page behind in view.
final List<RouteBase> assistantRoutes = [
  GoRoute(
    path: '/ask',
    pageBuilder: (context, s) {
      final request = s.extra is AskRequest ? s.extra! as AskRequest : null;
      if (MediaQuery.sizeOf(context).width >= panelBreakpoint) {
        return AskPanelPage<void>(
          key: s.pageKey,
          child: AskScreen(request: request, panel: true),
        );
      }
      return DenSheetPage<void>(
        key: s.pageKey,
        closeLabel: 'Close Ask',
        child: AskScreen(request: request),
      );
    },
  ),
];
