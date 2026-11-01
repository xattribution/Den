@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:den_net/den_net.dart';

import 'support/test.dart';

/// Backups sealed to the parents' recovery words (sealed_backup.dart): no passphrase to keep,
/// and older passphrase backups still open.
void main() {
  final plain = utf8.encode('{"v":1,"kind":"den_hub","files":{}}');

  test('the X25519 twin of an Ed25519 public key is the one its seed makes', () async {
    for (var i = 0; i < 4; i++) {
      final seed = randomBytes(32);
      final ed = await Ed25519().newKeyPairFromSeed(seed);
      final edPublic = (await ed.extractPublicKey()).bytes;
      final x = await x25519OfEd25519Seed(seed);
      expect(x25519PublicOfEd25519(edPublic), (await x.extractPublicKey()).bytes);
    }
  });

  test('a backup opens with any parent\'s recovery words, and only theirs', () async {
    final sam = RecoveryWords.generate(), alex = RecoveryWords.generate(), other = RecoveryWords.generate();
    final sealed = await sealBackup(
      plain,
      to: [
        BackupRecipient(member: 'm1', name: 'Sam', key: (await RecoveryWords.key(sam)).publicKey),
        BackupRecipient(member: 'm2', name: 'Alex', key: (await RecoveryWords.key(alex)).publicKey),
      ],
      madeAt: 1761621420000,
      familyName: 'The Riveras',
    );
    final info = readBackupInfo(sealed);
    expect(info.version, 2);
    expect(info.names, ['Sam', 'Alex']);
    expect(info.familyName, 'The Riveras');
    expect(info.madeAt, 1761621420000);
    expect(info.passphrase, isFalse);
    expect(await openBackup(sealed, words: sam), plain);
    expect(await openBackup(sealed, words: alex), plain);
    await expectLater(openBackup(sealed, words: other),
        throwsA(isA<BackupOpenException>().having((e) => e.reason, 'reason', BackupRefusal.wrongWords)));
    await expectLater(openBackup(sealed),
        throwsA(isA<BackupOpenException>().having((e) => e.reason, 'reason', BackupRefusal.needsWords)));
    // Nothing in the file is the plaintext or anyone's key.
    expect(utf8.decode(sealed, allowMalformed: true), isNot(contains('den_hub","files')));
  });

  test('a changed byte anywhere stops it opening', () async {
    final words = RecoveryWords.generate();
    final sealed = await sealBackup(plain, to: [BackupRecipient(member: 'm', name: 'Sam', key: (await RecoveryWords.key(words)).publicKey)]);
    final damaged = [...sealed]..[sealed.length - 20] ^= 1;
    await expectLater(openBackup(damaged, words: words),
        throwsA(isA<BackupOpenException>().having((e) => e.reason, 'reason', BackupRefusal.damaged)));
  });

  test('older backups sealed with a passphrase still open with it', () async {
    final old = await encryptBackup(plain, 'an old passphrase', params: const BackupParams(memoryKiB: 1024, iterations: 1, parallelism: 1));
    expect(readBackupInfo(old).version, 1);
    expect(await openBackup(old, passphrase: 'an old passphrase'), plain);
    await expectLater(openBackup(old, words: RecoveryWords.generate()),
        throwsA(isA<BackupOpenException>().having((e) => e.reason, 'reason', BackupRefusal.needsPassphrase)));
    await expectLater(openBackup(old, passphrase: 'not it'),
        throwsA(isA<BackupOpenException>().having((e) => e.reason, 'reason', BackupRefusal.wrongPassphrase)));
  });

  test('a passphrase given too opens it as well as the words', () async {
    final words = RecoveryWords.generate();
    final sealed = await sealBackup(
      plain,
      to: [BackupRecipient(member: 'm', name: 'Sam', key: (await RecoveryWords.key(words)).publicKey)],
      passphrase: 'from the old .env',
      params: const BackupParams(memoryKiB: 1024, iterations: 1, parallelism: 1),
    );
    expect(readBackupInfo(sealed).passphrase, isTrue);
    expect(await openBackup(sealed, passphrase: 'from the old .env'), plain);
    expect(await openBackup(sealed, words: words), plain);
  });

  test('nobody to open it is refused rather than written', () async {
    expect(() => sealBackup(plain, to: const []), throwsArgumentError);
  });
}
