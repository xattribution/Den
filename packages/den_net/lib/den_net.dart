/// Den's networking layer: encrypted device sessions, the sync protocol, pairing (QR invites,
/// spoken codes, matching words), the relay client and encrypted backups.
///
/// Pure Dart with no `dart:io`, so it runs in the app, in browsers, in the hub and in tests.
/// LAN discovery and shelf helpers live in `package:den_net/io.dart`.
library;

export 'src/backup.dart';
export 'src/client.dart';
export 'src/device_request.dart';
export 'src/invite.dart';
export 'src/mailbox.dart';
export 'src/recovery_words.dart';
export 'src/relay_client.dart';
export 'src/relay_protocol.dart';
export 'src/seal.dart';
export 'src/session.dart';
export 'src/spoken_code.dart';
export 'src/sync.dart';
export 'src/wordlist.dart' show wordList;
export 'src/words.dart' show matchingWords;
