import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import 'web_app.dart';

/// Making a passkey (`navigator.credentials.create`) or signing in with one (`get`).
enum PasskeyKind {
  create,
  get;
}

/// What the browser's passkey sheet answered.
sealed class PasskeyOutcome {
  const PasskeyOutcome();

  /// Reads den_web.js's answer: `{"credential": ...}` or `{"error": name}`.
  static PasskeyOutcome parse(String text) {
    try {
      final json = jsonDecode(text);
      if (json is Map && json['credential'] is Map) {
        return PasskeyAnswer(Map<String, Object?>.from(json['credential'] as Map));
      }
      if (json is Map && json['error'] is String) return PasskeyRefused(json['error'] as String);
    } on FormatException {
      // Not an answer.
    }
    return const PasskeyRefused('failed');
  }
}

/// The person chose a passkey (or made one), and was verified: the credential, as
/// `PublicKeyCredential.toJSON()` writes it, for the hub to check.
class PasskeyAnswer extends PasskeyOutcome {
  const PasskeyAnswer(this.credential);
  final Map<String, Object?> credential;
}

/// No passkey: [reason] is the browser's error name.
class PasskeyRefused extends PasskeyOutcome {
  const PasskeyRefused(this.reason);

  /// `NotAllowedError` (cancelled, timed out, or the tap didn't count), `InvalidStateError`
  /// (this device has one already), `not-ready` (no challenge armed), `unsupported`, ...
  final String reason;

  /// The person closed the sheet, or it timed out: nothing to say but "try again".
  bool get cancelled => reason == 'NotAllowedError' || reason == 'AbortError';

  /// Making one: this device (or the person's synced passwords) holds one of theirs already.
  bool get alreadyHere => reason == 'InvalidStateError';
}

/// The browser's passkeys, as den_web.js offers them; a fake in tests.
abstract class PasskeyBrowser {
  const PasskeyBrowser();

  /// The browser in use: the page's on the web, none elsewhere.
  static PasskeyBrowser current = kIsWeb ? const WebPasskeys() : const NoPasskeys();

  /// Whether this browser can make and use passkeys here: a secure page at a host name.
  bool get available;

  /// The page's host name, which must be the hub's RP ID.
  String get host;

  /// What the page says about the browser, for the words ("Face ID" on an iPhone).
  WebAppInfo get info => WebApp.info;

  /// Keeps the hub's [options] for [kind] in the page, ahead of the tap that uses them.
  bool arm(PasskeyKind kind, Map<String, Object?> options);

  /// Opens the browser's sheet with what [arm] kept. Must be the first thing a tap does.
  Future<PasskeyOutcome> start(PasskeyKind kind);

  /// A real, invisible `<button>` to lay over the one Flutter draws, whose own click opens the
  /// sheet and hands [onStart] the answer as it starts; null where there is none.
  Widget? overlay(PasskeyKind kind, void Function(Future<PasskeyOutcome> answer) onStart) => null;
}

/// Off the web: no passkeys (the apps get their own later).
class NoPasskeys extends PasskeyBrowser {
  const NoPasskeys();

  @override
  bool get available => false;

  @override
  String get host => '';

  @override
  bool arm(PasskeyKind kind, Map<String, Object?> options) => false;

  @override
  Future<PasskeyOutcome> start(PasskeyKind kind) async => const PasskeyRefused('unsupported');
}

/// The page's passkeys (web/den_web.js), with the click owned by a platform view's `<button>`:
/// see "passkeys" there for why.
class WebPasskeys extends PasskeyBrowser {
  const WebPasskeys();

  @override
  bool get available => WebApp.info.passkeys;

  @override
  String get host => Uri.base.host;

  @override
  bool arm(PasskeyKind kind, Map<String, Object?> options) => WebApp.passkeyArm(kind.name, jsonEncode(options));

  @override
  Future<PasskeyOutcome> start(PasskeyKind kind) => WebApp.passkeyGo(kind.name).then(PasskeyOutcome.parse);

  @override
  Widget? overlay(PasskeyKind kind, void Function(Future<PasskeyOutcome> answer) onStart) => HtmlElementView.fromTagName(
        tagName: 'button',
        // It paints nothing, so Flutter needn't split its canvas around it.
        isVisible: false,
        onElementCreated: (element) =>
            WebApp.passkeyBind(element, kind.name, (answer) => onStart(answer.then(PasskeyOutcome.parse))),
      );
}

/// How Den names a passkey on this device: Face ID on an iPhone, a fingerprint or the screen
/// lock on Android, and plainly "a passkey" anywhere else.
class PasskeyWords {
  const PasskeyWords._({
    required this.signIn,
    required this.offer,
    required this.make,
    required this.setUp,
    required this.done,
    required this.what,
  });

  /// For [web].
  factory PasskeyWords.of(WebAppInfo web) {
    if (web.ios && !web.ipad) {
      return const PasskeyWords._(
        signIn: 'Sign in with Face ID',
        offer: 'Use Face ID to get back in',
        make: 'Use Face ID',
        setUp: 'Face ID is set up',
        done: 'Done. Face ID gets you back in.',
        what: 'Face ID',
      );
    }
    if (web.ios) {
      return const PasskeyWords._(
        signIn: 'Sign in with Face ID or Touch ID',
        offer: 'Use Face ID or Touch ID to get back in',
        make: 'Use Face ID or Touch ID',
        setUp: 'Face ID or Touch ID is set up',
        done: 'Done. Face ID or Touch ID gets you back in.',
        what: 'Face ID or Touch ID',
      );
    }
    if (web.android) {
      return const PasskeyWords._(
        signIn: 'Sign in with your fingerprint',
        offer: 'Use your fingerprint or screen lock to get back in',
        make: 'Use fingerprint or screen lock',
        setUp: 'Your fingerprint or screen lock is set up',
        done: 'Done. Your fingerprint or screen lock gets you back in.',
        what: 'your fingerprint or screen lock',
      );
    }
    return const PasskeyWords._(
      signIn: 'Sign in with a passkey',
      offer: 'Use a passkey to get back in',
      make: 'Make a passkey',
      setUp: 'Your passkey is set up',
      done: 'Done. Your passkey gets you back in.',
      what: 'a passkey',
    );
  }

  /// The welcome screen's button: "Sign in with Face ID".
  final String signIn;

  /// The offer after joining: "Use Face ID to get back in".
  final String offer;

  /// Its button: "Use Face ID".
  final String make;

  /// On the person's page: "Face ID is set up".
  final String setUp;

  /// Once it's made: "Done. Face ID gets you back in."
  final String done;

  /// In a sentence: "Face ID", "your fingerprint or screen lock", "a passkey".
  final String what;
}
