import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// `window.denWeb` from web/den_web.js; null in a page without it (tests in a browser).
@JS('denWeb')
external _DenWeb? get _denWeb;

extension type _DenWeb._(JSObject _) implements JSObject {
  external String info();
  external JSPromise<JSBoolean> persist();
  external JSPromise<JSBoolean> holdEngine();
  external JSPromise<JSBoolean> waitForEngine();
  external JSPromise<JSString?> pushSubscription(String key);
  external JSPromise<JSString> pushState(String key);
  external JSPromise<JSString> subscribe(String key);
  external JSPromise<JSAny?> unsubscribe();
  external JSPromise<JSBoolean> setFamilies(String json);
  external JSPromise<JSString> share(String text);
  external JSPromise<JSString> copy(String text);
  external JSPromise<JSString> paste();
  external JSPromise<JSString> pickPhoto(bool camera);
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

Future<String?> pushState(String key) async {
  final web = _denWeb;
  if (web == null) return null;
  return (await web.pushState(key).toDart).toDart;
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

Future<void> setFamilies(String json) async {
  final web = _denWeb;
  if (web != null) await web.setFamilies(json).toDart;
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

Future<String> paste() async {
  final web = _denWeb;
  if (web == null) return '{"kind":"none"}';
  try {
    return (await web.paste().toDart).toDart;
  } on Object {
    return '{"kind":"none"}';
  }
}

/// Must be the first thing a tap does, like [subscribe].
Future<String> pickPhoto(bool camera) {
  final web = _denWeb;
  if (web == null) return Future.value('');
  final pending = web.pickPhoto(camera).toDart;
  return pending.then((answer) => answer.toDart, onError: (Object _) => 'error');
}

void listen(void Function(String route) onOpen) {
  _denWeb?.listen(((String route) => onOpen(route)).toJS);
}

// A page cached from before the keyboard fix has a denWeb without these two, so they're looked
// up rather than declared.

String? viewport() {
  final web = _denWeb;
  if (web == null || !web.has('viewport')) return null;
  try {
    return web.callMethod<JSString>('viewport'.toJS).toDart;
  } on Object {
    return null;
  }
}

void onViewport(void Function(String json) onChange) {
  final web = _denWeb;
  if (web == null || !web.has('onViewport')) return;
  web.callMethod<JSAny?>('onViewport'.toJS, ((String json) => onChange(json)).toJS);
}

// Newer still: Show screen info.

void diagnose(bool on) {
  final web = _denWeb;
  if (web == null || !web.has('diagnose')) return;
  web.callMethod<JSAny?>('diagnose'.toJS, on.toJS);
}

// Newer still: the keyboard at once.

bool keyboardNow() {
  final web = _denWeb;
  if (web == null || !web.has('keyboardNow')) return false;
  try {
    return web.callMethod<JSBoolean>('keyboardNow'.toJS).toDart;
  } on Object {
    return false;
  }
}

// Newer still: passkeys, looked up too.

bool passkeyArm(String kind, String json) {
  final web = _denWeb;
  if (web == null || !web.has('passkeyArm')) return false;
  try {
    return web.callMethod<JSBoolean>('passkeyArm'.toJS, kind.toJS, json.toJS).toDart;
  } on Object {
    return false;
  }
}

/// Must be the first thing a tap does: the call into the page happens before any await.
Future<String> passkeyGo(String kind) {
  final web = _denWeb;
  if (web == null || !web.has('passkeyGo')) return Future.value('{"error":"unsupported"}');
  final JSPromise<JSString> pending;
  try {
    pending = web.callMethod<JSPromise<JSString>>('passkeyGo'.toJS, kind.toJS);
  } on Object {
    return Future.value('{"error":"unsupported"}');
  }
  return pending.toDart.then((answer) => answer.toDart, onError: (Object _) => '{"error":"failed"}');
}

/// Makes [element] (a platform view's `<button>`) open the passkey sheet from its own click;
/// [onStart] gets the answer as it starts.
bool passkeyBind(Object element, String kind, void Function(Future<String> answer) onStart) {
  final web = _denWeb;
  if (web == null || !web.has('passkeyBind')) return false;
  void started(JSPromise<JSString> pending) =>
      onStart(pending.toDart.then((answer) => answer.toDart, onError: (Object _) => '{"error":"failed"}'));
  try {
    return web.callMethod<JSBoolean>('passkeyBind'.toJS, element as JSObject, kind.toJS, started.toJS).toDart;
  } on Object {
    return false;
  }
}

String? screenInfo() {
  final web = _denWeb;
  if (web == null || !web.has('screenInfo')) return null;
  try {
    return web.callMethod<JSString>('screenInfo'.toJS).toDart;
  } on Object {
    return null;
  }
}

/// Fetches [path] from the page's own server, past the service worker and any cache: the text,
/// or null when it can't be had.
Future<String?> fetchFresh(String path) async {
  try {
    final url = '$path${path.contains('?') ? '&' : '?'}den-check=${DateTime.now().millisecondsSinceEpoch}';
    final response = await _fetch(url.toJS, _FetchOptions(cache: 'no-store')).toDart;
    if (!response.ok) return null;
    return (await response.text().toDart).toDart;
  } on Object {
    return null;
  }
}

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url, _FetchOptions options);

extension type _FetchOptions._(JSObject _) implements JSObject {
  external factory _FetchOptions({String cache});
}

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external JSPromise<JSString> text();
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
