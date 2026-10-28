import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../platform/capabilities.dart';
import '../../../platform/web/web_app.dart';
import '../../family/family.dart';

/// The kinds a person picks for the device in their hand; hubs and displays are chosen by mode.
const personalKinds = [DeviceKind.phone, DeviceKind.tablet, DeviceKind.desktop, DeviceKind.browser];

/// A sensible kind for the device the app is running on.
DeviceKind guessDeviceKind(BuildContext context) {
  if (Capabilities.web) return WebApp.info.kind;
  if (Capabilities.mobile) return MediaQuery.sizeOf(context).shortestSide >= 600 ? DeviceKind.tablet : DeviceKind.phone;
  return DeviceKind.desktop;
}

/// "Sam's phone", from a person's name and the device kind ("Sam's iPhone" in Safari on one).
String suggestDeviceName(String personName, DeviceKind kind) {
  final apple = Capabilities.web && WebApp.info.ios;
  final word = switch (kind) {
    DeviceKind.phone => apple ? 'iPhone' : 'phone',
    DeviceKind.tablet => apple ? 'iPad' : 'tablet',
    DeviceKind.desktop => 'computer',
    DeviceKind.browser => 'browser',
    DeviceKind.hub => 'hub',
    DeviceKind.display => 'display',
  };
  final name = personName.trim();
  if (name.isEmpty) return apple && (kind == DeviceKind.phone || kind == DeviceKind.tablet) ? word : FamilyWords.deviceKind(kind);
  return '${FamilyWords.possessive(name)} $word';
}
