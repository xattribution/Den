import 'package:web/web.dart' as web;

/// The page's own cookie [name], or null.
String? read(String name) {
  try {
    for (final part in web.document.cookie.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0 && part.substring(0, eq).trim() == name) return part.substring(eq + 1).trim();
    }
  } on Object {
    // A page that may not use cookies keeps nothing.
  }
  return null;
}

/// Sets the page's own cookie [name] for the whole site, sent only to this site and, over
/// https, only over https; a [maxAgeSeconds] of 0 removes it.
void write(String name, String value, int maxAgeSeconds) {
  try {
    final secure = web.window.location.protocol == 'https:' ? '; Secure' : '';
    web.document.cookie = '$name=$value; Max-Age=$maxAgeSeconds; Path=/; SameSite=Strict$secure';
  } on Object {
    // Nothing kept: Copy invite and Paste an invite still work.
  }
}
