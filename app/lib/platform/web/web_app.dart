import 'dart:convert';
import 'dart:typed_data';

import 'package:den_core/den_core.dart' show DeviceKind;
import 'package:flutter/foundation.dart' show immutable;

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
    this.mobile = false,
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
      mobile: json['mobile'] == true,
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

  /// A phone or tablet's browser, whose file picker can open the camera.
  final bool mobile;

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

/// What [WebApp.paste] found on the clipboard.
class WebPaste {
  const WebPaste.text(String this.text)
      : bytes = null,
        type = null;
  const WebPaste.image(List<int> this.bytes, String this.type) : text = null;
  const WebPaste.none()
      : text = null,
        bytes = null,
        type = null;

  final String? text;
  final List<int>? bytes;

  /// The image's media type, such as `image/png`.
  final String? type;

  bool get isEmpty => text == null && bytes == null;
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

/// How the page stands around the keyboard, as `window.denWeb.viewport()` says
/// (web/den_web.js). All in CSS pixels, which are Flutter's logical pixels.
@immutable
class WebViewport {
  const WebViewport({this.keyboard = 0, this.width = 0, this.height = 0, this.top = 0, this.scrolled = 0, this.editing = false});

  /// Null when the answer isn't one.
  static WebViewport? fromJson(Object? json) {
    if (json is! Map) return null;
    double n(String key) => json[key] is num ? (json[key] as num).toDouble() : 0;
    return WebViewport(
      keyboard: n('keyboard'),
      width: n('width'),
      height: n('height'),
      top: n('top'),
      scrolled: n('scrolled'),
      editing: json['editing'] == true,
    );
  }

  /// How much of the screen the on-screen keyboard covers; 0 when it's down, however the
  /// browser's visual viewport was left after it closed.
  final double keyboard;

  /// The page's own size (the layout viewport), which is what Flutter lays out on.
  final double width;
  final double height;

  /// How far the visual viewport is panned down the page, and the page scrolled; both 0 once
  /// den_web.js has put the page back.
  final double top;
  final double scrolled;

  /// A text field has the browser's focus.
  final bool editing;

  @override
  bool operator ==(Object other) =>
      other is WebViewport &&
      other.keyboard == keyboard &&
      other.width == width &&
      other.height == height &&
      other.top == top &&
      other.scrolled == scrolled &&
      other.editing == editing;

  @override
  int get hashCode => Object.hash(keyboard, width, height, top, scrolled, editing);

  @override
  String toString() => 'WebViewport(keyboard: $keyboard, $width x $height, top: $top, scrolled: $scrolled, editing: $editing)';
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

  /// This browser's subscription whatever key it was made for, and whether that is [key]: a
  /// device in several families keeps a family's own subscription until a tap replaces it with
  /// one for the key they share ([subscribe] does).
  static Future<({WebPushSubscription? subscription, bool same})> pushState(String key) async {
    final text = await impl.pushState(key);
    if (text == null) return (subscription: null, same: false);
    try {
      final json = jsonDecode(text);
      if (json is! Map) return (subscription: null, same: false);
      return (subscription: WebPushSubscription.fromJson(json['subscription']), same: json['same'] == true);
    } on FormatException {
      return (subscription: null, same: false);
    }
  }

  /// Subscribes to pushes for the hub's [key], replacing a subscription made for another key.
  /// Call it straight from a tap, before awaiting anything: Safari asks for permission only in a
  /// user gesture. Throws [WebPushException].
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

  /// Tells the service worker the families this browser holds, by id with their names: it titles
  /// a family's push with the name kept here, and shows nothing of a push from any other.
  static Future<void> setFamilies(Map<String, String> families) => impl.setFamilies(jsonEncode(families));

  /// Opens the share sheet with [text], or copies it where there is none. Call it straight from
  /// a tap.
  static Future<ShareOutcome> share(String text) async =>
      ShareOutcome.values.asNameMap()[await impl.share(text)] ?? ShareOutcome.failed;

  /// Copies [text]. Call it straight from a tap.
  static Future<bool> copy(String text) async => await impl.copy(text) == 'copied';

  /// Routes from tapped notifications, including ones tapped before the app listened.
  static void listen(void Function(String route) onOpen) => impl.listen(onOpen);

  /// What's on the clipboard: an image, text, or nothing Den can read (or the browser said no).
  /// Call it straight from a tap.
  static Future<WebPaste> paste() async {
    try {
      final json = jsonDecode(await impl.paste());
      if (json is Map) {
        if (json['kind'] == 'image' && json['data'] is String) {
          return WebPaste.image(base64Decode(json['data'] as String), json['type'] as String? ?? 'image/png');
        }
        if (json['kind'] == 'text' && json['text'] is String) return WebPaste.text(json['text'] as String);
      }
    } on Object {
      // Nothing readable.
    }
    return const WebPaste.none();
  }

  /// A photo from the browser's picker (a file input taking `image/*`, which on an iPhone or
  /// iPad offers Take Photo and Photo Library), made small in the page: its center square at
  /// 256 pixels as a JPEG under 40 KB. [camera] opens the camera straight away where the
  /// browser can. Null when nothing was picked. Call it straight from a tap. Throws
  /// [FormatException] when the image couldn't be read.
  static Future<Uint8List?> pickPhoto({bool camera = false}) async {
    final answer = await impl.pickPhoto(camera);
    if (answer.isEmpty) return null;
    if (answer == 'error') throw const FormatException('unreadable');
    return base64Decode(answer);
  }

  /// The safe areas (top, right, bottom, left) in logical pixels.
  static List<double> insets() => impl.insets();

  /// How the page stands around the keyboard; null off the web or without den_web.js.
  static WebViewport? viewport() {
    final text = impl.viewport();
    if (text == null) return null;
    try {
      return WebViewport.fromJson(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }

  /// Calls [onChange] now and whenever the keyboard or the page moves (after den_web.js has put
  /// the page back at the top). Does nothing off the web or without den_web.js; one listener at
  /// a time, the app's root.
  static void onViewport(void Function(WebViewport viewport) onChange) => impl.onViewport((text) {
        try {
          final viewport = WebViewport.fromJson(jsonDecode(text));
          if (viewport != null) onChange(viewport);
        } on FormatException {
          // Not an answer; the next change brings one.
        }
      });

  /// Starts (or stops) the page keeping its last few viewport and focus events for
  /// [screenInfo]. Off until Show screen info turns it on.
  static void diagnose(bool on) => impl.diagnose(on);

  /// What the page knows about the screen, the keyboard, the focus and its last few viewport
  /// events (web/den_web.js `screenInfo`); null off the web or without den_web.js.
  static Map<String, Object?>? screenInfo() {
    final text = impl.screenInfo();
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      return json is Map ? Map<String, Object?>.from(json) : null;
    } on FormatException {
      return null;
    }
  }

  /// [path] fetched fresh from the server the app came from (past the service worker and any
  /// cache), relative to the page: the hub's `build.json` or `health`. Null off the web, or when
  /// it can't be had.
  static Future<String?> fetchFresh(String path) => impl.fetchFresh(path);

  /// Loads the page again, as when Den opens.
  static void reload() => impl.reload();
}
