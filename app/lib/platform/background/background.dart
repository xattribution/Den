/// Background refresh for phones, and the lock that keeps one Den engine per process. Browsers
/// have neither; they get stand-ins that do nothing.
library;

export 'background_stub.dart' if (dart.library.io) 'background_refresh.dart';
