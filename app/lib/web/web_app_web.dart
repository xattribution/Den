import 'dart:convert';
import 'dart:js_interop';

/// `window.denWeb` from web/den_web.js; null in a page without it (tests in a browser).
@JS('denWeb')
external _DenWeb? get _denWeb;

extension type _DenWeb._(JSObject _) implements JSObject {
  external String info();
  external JSPromise<JSBoolean> persist();
  external JSPromise<JSBoolean> holdEngine();
  external JSPromise<JSBoolean> waitForEngine();
  external JSPromise<JSString?> pushSubscription(String key);
  external JSPromise<JSString> subscribe(String key);
  external JSPromise<JSAny?> unsubscribe();
  external JSPromise<JSString> share(String text);
  external JSPromise<JSString> copy(String text);
  external void listen(JSFunction onOpen);
  external String insets();
  external void reload();
}

void reload() => _denWeb?.reload();

String? info() => _denWeb?.info();

Future<bool> persist() async {
  final web = _denWeb;
  if (web == null) return false;
  try {
    return (await web.persist().toDart).toDart;
  } on Object {
    return false;
  }
}

Future<bool> holdEngine() async {
  final web = _denWeb;
  if (web == null) return true;
  return (await web.holdEngine().toDart).toDart;
}

Future<void> waitForEngine() async {
  final web = _denWeb;
  if (web != null) await web.waitForEngine().toDart;
}

Future<String?> pushSubscription(String key) async {
  final web = _denWeb;
  if (web == null) return null;
  return (await web.pushSubscription(key).toDart)?.toDart;
}

/// Must be the first thing a tap does: the call into the page happens before any await.
Future<String?> subscribe(String key) {
  final web = _denWeb;
  if (web == null) return Future.value(null);
  final pending = web.subscribe(key).toDart;
  return pending.then((answer) => answer.toDart);
}

Future<void> unsubscribe() async {
  final web = _denWeb;
  if (web != null) await web.unsubscribe().toDart;
}

/// Must be the first thing a tap does, like [subscribe].
Future<String> share(String text) {
  final web = _denWeb;
  if (web == null) return Future.value('failed');
  final pending = web.share(text).toDart;
  return pending.then((outcome) => outcome.toDart);
}

Future<String> copy(String text) {
  final web = _denWeb;
  if (web == null) return Future.value('failed');
  final pending = web.copy(text).toDart;
  return pending.then((outcome) => outcome.toDart);
}

void listen(void Function(String route) onOpen) {
  _denWeb?.listen(((String route) => onOpen(route)).toJS);
}

List<double> insets() {
  final web = _denWeb;
  if (web == null) return const [0, 0, 0, 0];
  try {
    final values = jsonDecode(web.insets());
    if (values is List && values.length == 4) return [for (final v in values) v is num ? v.toDouble() : 0.0];
  } on Object {
    // No insets to read.
  }
  return const [0, 0, 0, 0];
}
