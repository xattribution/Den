import 'dart:async';

import 'package:den_core/demo.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';

/// "Look around with a demo family": an in-memory demo family that never touches this device's
/// own log, swapped into the app's state. Leaving it brings back the real engine, which still
/// has no family, so the person lands on the welcome screen again.
abstract final class DemoSession {
  static Den? _real;

  static bool get active => _real != null;

  static AppState? _state;

  static Future<void> start(BuildContext context) async {
    final state = DenScope.read(context);
    final demo = await createDemoFamily();
    _real = state.den;
    _state = state;
    state.replaceDen(demo);
  }

  static void leave() {
    final real = _real;
    final state = _state;
    if (real == null || state == null) return;
    final demo = state.den;
    _real = null;
    _state = null;
    state.replaceDen(real);
    unawaited(demo.close());
  }
}
