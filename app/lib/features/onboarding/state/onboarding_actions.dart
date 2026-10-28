import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/den_scope.dart';

/// Founding a family on this device. Device-local: a family is founded once, on the founding
/// parent's own device, so no action offers it. Adding people after is the family's
/// `addPerson`, an action like any other.
class OnboardingActions {
  const OnboardingActions(this._den);

  final Den _den;

  Future<void> foundFamily({
    required String familyName,
    required String timezone,
    required String yourName,
    required Marker marker,
    required String picture,
    required String deviceName,
    required DeviceKind deviceKind,
  }) =>
      _den.createFamily(
        familyName: familyName,
        timezone: timezone,
        yourName: yourName,
        marker: marker,
        picture: picture,
        deviceName: deviceName,
        deviceKind: deviceKind,
      );
}

extension OnboardingActionsOf on BuildContext {
  OnboardingActions get onboardingActions => OnboardingActions(actions.den);
}
