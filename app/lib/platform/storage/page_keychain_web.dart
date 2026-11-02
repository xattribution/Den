import 'package:web/web.dart' as web;

/// Whether this page keeps its keys in its own storage: a page opened at a plain `http://`
/// address on the home network or a VPN, where the browser gives no Web Crypto, so the keychain
/// the app uses everywhere else can't run. Those keys stay in this browser's storage for the
/// page's address.
bool get pageKeychainOnly => !web.window.isSecureContext;

const _prefix = 'den.keychain.';

String? pageRead(String key) => web.window.localStorage.getItem('$_prefix$key');

void pageWrite(String key, String value) => web.window.localStorage.setItem('$_prefix$key', value);

void pageDelete(String key) => web.window.localStorage.removeItem('$_prefix$key');
