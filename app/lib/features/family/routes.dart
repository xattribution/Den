import 'package:go_router/go_router.dart';

import 'screens/device_screen.dart';
import 'screens/family_screen.dart';
import 'screens/link_browser_screen.dart';
import 'screens/member_editor.dart';

/// `/family` and its people and devices: `devices/add` (with `browser` and the [addDevice] pages
/// other features offer), `member/new?role=`, `member/:id`, `device/:id`.
GoRoute familyRoute({List<RouteBase> addDevice = const []}) => GoRoute(
      path: '/family',
      builder: (_, _) => const FamilyScreen(),
      routes: [
        GoRoute(
          path: 'devices/add',
          builder: (_, _) => const AddDeviceScreen(),
          routes: [
            ...addDevice,
            GoRoute(path: 'browser', builder: (_, _) => const LinkBrowserScreen()),
          ],
        ),
        GoRoute(path: 'member/new', builder: (_, s) => MemberEditor(role: s.uri.queryParameters['role'])),
        GoRoute(path: 'member/:id', builder: (_, s) => MemberEditor(memberId: s.pathParameters['id'])),
        GoRoute(path: 'device/:id', builder: (_, s) => DeviceScreen(deviceId: s.pathParameters['id']!)),
      ],
    );
