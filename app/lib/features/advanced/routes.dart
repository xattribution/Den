import 'package:go_router/go_router.dart';

import 'screens/add_hub_screen.dart';
import 'screens/advanced_screen.dart';
import 'screens/computer_link_screen.dart';
import 'screens/connect_guide_screen.dart';
import 'screens/connections_screen.dart';
import 'screens/create_token_screen.dart';
import 'screens/data_screen.dart';
import 'screens/displays_screen.dart';
import 'screens/history_screen.dart';
import 'screens/home_assistant_screen.dart';
import 'screens/hub_screen.dart';
import 'screens/link_browser_screen.dart';
import 'screens/nearby_device_screen.dart';
import 'screens/reader_screen.dart';
import 'screens/search_screen.dart';

/// What changed and finding things: `/history?q=`, `/search?q=`.
final List<RouteBase> advancedRoutes = [
  GoRoute(path: '/history', builder: (_, s) => HistoryScreen(query: s.uri.queryParameters['q'])),
  GoRoute(path: '/search', builder: (_, s) => SearchScreen(query: s.uri.queryParameters['q'])),
];

/// Under `/settings`: `advanced` (with `hub`, its `add`, `computer`, `browser` and `nearby`, `displays` and
/// `data`), `connections` (with `new?label=`, `guide` and `reader`) and `home-assistant`.
final List<RouteBase> advancedSettingsRoutes = [
  GoRoute(
    path: 'advanced',
    builder: (_, _) => const AdvancedScreen(),
    routes: [
      GoRoute(
        path: 'hub',
        builder: (_, _) => const HubScreen(),
        routes: [
          GoRoute(path: 'add', builder: (_, _) => const AddHubScreen()),
          GoRoute(path: 'computer', builder: (_, _) => const ComputerLinkScreen()),
          GoRoute(path: 'browser', builder: (_, _) => const LinkBrowserScreen()),
          GoRoute(path: 'nearby', builder: (_, _) => const NearbyDeviceScreen()),
        ],
      ),
      GoRoute(path: 'displays', builder: (_, _) => const DisplaysScreen()),
      GoRoute(path: 'data', builder: (_, _) => const DataScreen()),
    ],
  ),
  GoRoute(
    path: 'connections',
    builder: (_, _) => const ConnectionsScreen(),
    routes: [
      GoRoute(path: 'new', builder: (_, s) => CreateTokenScreen(label: s.uri.queryParameters['label'])),
      GoRoute(path: 'guide', builder: (_, _) => const ConnectGuideScreen()),
      GoRoute(path: 'reader', builder: (_, _) => const ReaderScreen()),
    ],
  ),
  GoRoute(path: 'home-assistant', builder: (_, _) => const HomeAssistantScreen()),
];

/// Under `/family/devices/add`, where older links point: they land in Advanced.
final List<RouteBase> advancedAddDeviceRoutes = [
  GoRoute(path: 'hub', redirect: (_, _) => '/settings/advanced/hub/add'),
  GoRoute(path: 'browser', redirect: (_, _) => '/settings/advanced/hub/browser'),
];
