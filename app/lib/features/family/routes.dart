import 'package:go_router/go_router.dart';

import 'screens/family_screen.dart';

/// `/family`, and `/family/member/:id` for one person's page. Adding devices lives in Advanced
/// now: the old `/family/devices/add` links land there, with the [addDevice] pages other
/// features keep under it.
GoRoute familyRoute({List<RouteBase> addDevice = const []}) => GoRoute(
      path: '/family',
      builder: (_, _) => const FamilyScreen(),
      routes: [
        GoRoute(
          path: 'devices/add',
          redirect: (_, s) => s.matchedLocation == '/family/devices/add' ? '/settings/advanced/hub' : null,
          routes: addDevice,
        ),
        GoRoute(path: 'member/:id', builder: (_, s) => FamilyScreen(selected: s.pathParameters['id'])),
      ],
    );
