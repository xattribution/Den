import 'dart:convert';

import 'package:den_core/den_core.dart' show DeviceKind;

import 'web_app_stub.dart' if (dart.library.js_interop) 'web_app_web.dart' as impl;

/// What the browser says about where Den runs (from `window.denWeb`, web/den_web.js). Off the
/// web, and in a page without den_web.js, every answer is "no".
class WebAppInfo {
  const WebAppInfo({
    this.ios = false,
    this.iosVersion,
    this.ipad = false,
    this.standalone = false,
    this.secure = false,
    this.worker = false,
    this.push = false,
    this.permission = 'unsupported',
    this.share = false,
    this.ready = false,
  });

  factory WebAppInfo.fromJson(Map<String, Object?> json) {
    final version = json['ios_version'];
    return WebAppInfo(
      ios: json['ios'] == true,
      iosVersion: version is List && version.length == 2 && version.every((v) => v is num)
          ? (major: (version[0] as num).toInt(), minor: (version[1] as num).toInt())
          : null,
      ipad: json['ipad'] == true,
      standalone: json['standalone'] == true,
      secure: json['secure'] == true,
      worker: json['worker'] == true,
      push: json['push'] == true,
      permission: json['permission'] as String? ?? 'unsupported',
      share: json['share'] == true,
      ready: json['ready'] == true,
    );
  }

  /// An iPhone, iPad or iPod.
  final bool ios;
  final ({int major, int minor})? iosVersion;
  final bool ipad;

  /// Opened from the Home Screen as its own app.
  final bool standalone;

  /// An https page (or localhost): what service workers, Web Push and Web Crypto need.
  final bool secure;
  final bool worker;

  /// The page can subscribe to Web Push (on iOS, only Home Screen apps on 16.4 and later).
  final bool push;

  /// Notification permission: `default`, `granted`, `denied` or `unsupported`.
  final String permission;

  /// The share sheet is there.
  final bool share;

  /// The service worker is running, so a tap can subscribe to pushes at once.
  final bool ready;

  /// Safari on an iPhone or iPad, not opened from the Home Screen. Den belongs on the Home
  /// Screen there: the Home Screen app keeps its own storage, separate from Safari's, and only
  /// it can show reminders.
  bool get needsHomeScreen => ios && !standalone;

  /// iOS before 16.4, which has no Web Push.
  bool get iosTooOld {
    final v = iosVersion;
    return ios && v != null && (v.major < 16 || (v.major == 16 && v.minor < 4));
  }

  /// The kind of device this browser runs on, for its device record.
  DeviceKind get kind => ios ? (ipad ? DeviceKind.tablet : DeviceKind.phone) : DeviceKind.browser;
}

/// Whether this browser can get reminders from the hub, and if not, why.
enum PushAvailability {
  /// A tap can turn them on.
  ready,

  /// Safari on iOS: add Den to the Home Screen and open it from there first.
  addToHomeScreen,

  /// iOS before 16.4.
  updateIos,

  /// The page isn't https.
  needsHttps,

  /// Notifications were turned off for Den.
  blocked,

  /// This browser has no Web Push.
  unsupported,
}

PushAvailability pushAvailability(WebAppInfo info) {
  if (info.iosTooOld) return PushAvailability.updateIos;
  if (!info.secure) return PushAvailability.needsHttps;
  if (info.needsHomeScreen) return PushAvailability.addToHomeScreen;
  if (!info.push) return PushAvailability.unsupported;
  if (info.permission == 'denied') return PushAvailability.blocked;
  return PushAvailability.ready;
}

/// What happened to text handed to the share sheet.
enum ShareOutcome { shared, copied, cancelled, failed }

/// A push subscription as the browser gives it (`PushSubscription.toJSON()`): the push
/// service's endpoint and the keys the hub encrypts with.
class WebPushSubscription {
  const WebPushSubscription({required this.endpoint, required this.p256dh, required this.auth});

  static WebPushSubscription? fromJson(Object? json) {
    if (json is! Map) return null;
    final keys = json['keys'];
    final endpoint = json['endpoint'];
    if (endpoint is! String || keys is! Map) return null;
    final p256dh = keys['p256dh'], auth = keys['auth'];
    if (p256dh is! String || auth is! String) return null;
    return WebPushSubscription(endpoint: endpoint, p256dh: p256dh, auth: auth);
  }

  final String endpoint;
  final String p256dh;
  final String auth;

  Map<String, Object?> toJson() => {
        'endpoint': endpoint,
        'keys': {'p256dh': p256dh, 'auth': auth},
      };
}

/// Subscribing failed; [reason] is the browser's error name (`NotAllowedError` when the person
/// said no) or `not-ready` / `unsupported`.
class WebPushException implements Exception {
  const WebPushException(this.reason);
  final String reason;

  @override
  String toString() => 'WebPushException($reason)';
}

/// The page's side of Den in a browser: see web/den_web.js.
abstract final class WebApp {
  static WebAppInfo get info {
    final text = impl.info();
    if (text == null) return const WebAppInfo();
    try {
      return WebAppInfo.fromJson(Map<String, Object?>.from(jsonDecode(text) as Map));
    } on Object {
      return const WebAppInfo();
    }
  }

  /// Asks the browser to keep Den's storage when space runs low.
  static Future<bool> persist() => impl.persist();

  /// Holds the one-engine lock for this page; false while another tab has it.
  static Future<bool> holdEngine() => impl.holdEngine();

  /// Waits for the other tab to let go of the engine, then holds it.
  static Future<void> waitForEngine() => impl.waitForEngine();

  /// This browser's subscription for the hub's [key], or null. A subscription for another key
  /// is dropped.
  static Future<WebPushSubscription?> pushSubscription(String key) async {
    final text = await impl.pushSubscription(key);
    if (text == null) return null;
    try {
      return WebPushSubscription.fromJson(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }

  /// Subscribes to pushes for the hub's [key]. Call it straight from a tap, before awaiting
  /// anything: Safari asks for permission only in a user gesture. Throws [WebPushException].
  static Future<WebPushSubscription> subscribe(String key) async {
    final text = await impl.subscribe(key);
    Object? json;
    try {
      json = text == null ? null : jsonDecode(text);
    } on FormatException {
      json = null;
    }
    if (json is Map && json['subscription'] != null) {
      final subscription = WebPushSubscription.fromJson(json['subscription']);
      if (subscription != null) return subscription;
    }
    throw WebPushException(json is Map ? json['error'] as String? ?? 'failed' : 'unsupported');
  }

  static Future<void> unsubscribe() => impl.unsubscribe();

  /// Opens the share sheet with [text], or copies it where there is none. Call it straight from
  /// a tap.
  static Future<ShareOutcome> share(String text) async =>
      ShareOutcome.values.asNameMap()[await impl.share(text)] ?? ShareOutcome.failed;

  /// Copies [text]. Call it straight from a tap.
  static Future<bool> copy(String text) async => await impl.copy(text) == 'copied';

  /// Routes from tapped notifications, including ones tapped before the app listened.
  static void listen(void Function(String route) onOpen) => impl.listen(onOpen);

  /// The safe areas (top, right, bottom, left) in logical pixels.
  static List<double> insets() => impl.insets();

  /// Loads the page again, as when Den opens.
  static void reload() => impl.reload();
}
