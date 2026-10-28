import 'package:go_router/go_router.dart';

import 'screens/today_screen.dart';

/// The Today tab: `/today`.
StatefulShellBranch todayBranch() => StatefulShellBranch(
      routes: [GoRoute(path: '/today', builder: (_, _) => const TodayScreen())],
    );
