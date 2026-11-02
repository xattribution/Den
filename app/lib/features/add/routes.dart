import 'package:den_capture/den_capture.dart' show CaptureInput;
import 'package:go_router/go_router.dart';

import 'screens/capture_screen.dart';
import 'state/capture_service.dart' show CaptureProblem;

/// What Den read from something shared or picked: `/capture`, with the input (or why it
/// couldn't be read) as the route's extra.
final List<RouteBase> addRoutes = [
  GoRoute(
    path: '/capture',
    builder: (_, s) => CaptureRoute(
      input: s.extra is CaptureInput ? s.extra! as CaptureInput : null,
      problem: s.extra is CaptureProblem ? (s.extra! as CaptureProblem).message : null,
    ),
  ),
];
