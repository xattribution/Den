import 'package:den_hub/den_hub.dart';

import 'fake_idp.dart';
import 'oidc_keys.dart';

/// Where [google] and [apple] are, for [HubConfig.signInIssuers] or [HostConfig.signInIssuers].
Map<String, Uri> issuersOf({FakeIdp? google, FakeIdp? apple}) => {
      if (google != null) googleProvider: google.issuerUri,
      if (apple != null) appleProvider: apple.issuerUri,
    };

/// Turns [google] and [apple] on for every family on [host], as a parent of its own family does
/// from the app, without the checks the API makes first. [appleKey] is the `.p8` (Apple's own by
/// default).
Future<void> turnOnSignIn(DenHost host, {FakeIdp? google, FakeIdp? apple, String appleKey = appleP8}) async {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  if (google != null) {
    await host.signIn.setGoogle(GoogleClient(clientId: google.clientId, clientSecret: google.clientSecret), now: now);
  }
  if (apple != null) {
    await host.signIn.setApple(
      AppleClient(servicesId: apple.clientId, teamId: apple.teamId, keyId: apple.keyId, key: appleKey),
      now: now,
    );
  }
}
