/// Outside a browser there is no page to keep keys in; see page_keychain_web.dart.
bool get pageKeychainOnly => false;

String? pageRead(String key) => null;

void pageWrite(String key, String value) {}

void pageDelete(String key) {}
