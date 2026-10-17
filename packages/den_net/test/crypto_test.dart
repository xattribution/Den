import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

Change fakeChange(String device, int counter, {String space = 'f', Map<String, Object?>? fields}) => Change(
      id: '$device:$counter',
      space: space,
      hlc: Hlc(1700000000000 + counter, 0, device),
      type: 'item',
      rid: 'r$counter',
      fields: fields ?? {'text': 'milk $counter'},
      device: device,
      actor: null,
      sig: 'sig',
    );

void main() {
  group('word list', () {
    test('is the BIP-39 English list', () async {
      expect(wordList, hasLength(2048));
      expect([...wordList]..sort(), wordList);
      expect(wordList.map((w) => w.substring(0, w.length < 4 ? w.length : 4)).toSet(), hasLength(2048));
      final digest = await Sha256().hash(utf8.encode(wordList.map((w) => '$w\n').join()));
      expect(
        digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda',
      );
    });
  });

  group('encrypted backups', () {
    final data = utf8.encode(jsonEncode({'family': 'The Parks', 'changes': List.generate(50, (i) => 'c$i')}));

    test('round trip with the standard Argon2id parameters, and a wrong passphrase fails', () async {
      final sealed = await encryptBackup(data, 'correct horse battery staple');
      expect(utf8.decode(sealed.sublist(0, 4)), 'DENB');
      expect(sealed[4], 1);
      expect(sealed.length, greaterThan(data.length));
      expect(String.fromCharCodes(sealed).contains('The Parks'), isFalse);
      expect(await decryptBackup(sealed, 'correct horse battery staple'), data);
      await expectLater(decryptBackup(sealed, 'correct horse battery stapler'), throwsA(isA<BackupException>()));
    });

    test('detects tampering with the header or the ciphertext', () async {
      const params = BackupParams(memoryKiB: 64, iterations: 1, parallelism: 1);
      final sealed = await encryptBackup(data, 'pw', params: params);
      expect(await decryptBackup(sealed, 'pw'), data);
      final body = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1;
      await expectLater(decryptBackup(body, 'pw'), throwsA(isA<BackupException>()));
      final salt = Uint8List.fromList(sealed)..[20] ^= 1;
      await expectLater(decryptBackup(salt, 'pw'), throwsA(isA<BackupException>()));
    });

    test('refuses files that are not backups or ask for absurd costs', () async {
      await expectLater(decryptBackup(utf8.encode('hello world, not a backup at all......' * 3), 'pw'),
          throwsA(isA<BackupException>()));
      const params = BackupParams(memoryKiB: 64, iterations: 1, parallelism: 1);
      final sealed = await encryptBackup(data, 'pw', params: params);
      final greedy = Uint8List.fromList(sealed)..setRange(6, 10, [0x7f, 0xff, 0xff, 0xff]);
      await expectLater(decryptBackup(greedy, 'pw'), throwsA(isA<BackupException>()));
    });
  });

  group('sealing to a device', () {
    late DeviceKeys parent;
    late DeviceKeys tablet;
    late DeviceKeys other;

    setUpAll(() async {
      parent = await DeviceKeys.generate();
      tablet = await DeviceKeys.generate();
      other = await DeviceKeys.generate();
    });

    test('a space key round trips to the recipient', () async {
      final key = randomBytes(32);
      final envelope = await sealSpaceKey(
        sender: parent,
        recipientDevice: await tablet.deviceId(),
        recipientXpub: tablet.xpub,
        grant: SpaceKeyGrant(space: 'f', epoch: 3, key: key),
      );
      expect(jsonEncode(envelope), isNot(contains(b64e(key))));
      expect(sealedSender(envelope), await parent.deviceId());
      final grant = await openSpaceKey(envelope, recipient: tablet, senderPubkey: parent.pubkey);
      expect(grant.space, 'f');
      expect(grant.epoch, 3);
      expect(grant.key, key);
    });

    test('fails for another recipient, another sender key, or tampering', () async {
      final envelope = await sealToDevice(
        sender: parent,
        recipientDevice: await tablet.deviceId(),
        recipientXpub: tablet.xpub,
        payload: {'hello': 'tablet'},
      );
      await expectLater(openSealed(envelope, recipient: other, senderPubkey: parent.pubkey),
          throwsA(isA<SealException>()));
      await expectLater(openSealed(envelope, recipient: tablet, senderPubkey: other.pubkey),
          throwsA(isA<SealException>()));
      final ct = b64d(envelope['ct']! as String)..[0] ^= 1;
      await expectLater(
        openSealed({...envelope, 'ct': b64e(ct)}, recipient: tablet, senderPubkey: parent.pubkey),
        throwsA(isA<SealException>()),
      );
      // Re-signing tampered ciphertext with another key doesn't help either.
      expect(await openSealed(envelope, recipient: tablet, senderPubkey: parent.pubkey), {'hello': 'tablet'});
    });
  });

  group('mailbox blobs', () {
    test('ids are HMAC(space key, "mailbox:<epoch>") hex', () async {
      final key = randomBytes(32);
      final id = await mailboxId(key, 0);
      expect(id, matches(relayKeyPattern));
      final mac = await Hmac.sha256().calculateMac(utf8.encode('mailbox:0'), secretKey: SecretKey(key));
      expect(id, mac.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
      expect(await mailboxId(key, 1), isNot(id));
    });

    test('changes round trip and only open with the same key, space and epoch', () async {
      final key = randomBytes(32);
      final changes = [fakeChange('dev1', 1), fakeChange('dev1', 2)];
      final blob = await sealChanges(key, space: 'f', epoch: 0, changes: changes);
      expect(utf8.decode(blob, allowMalformed: true), isNot(contains('milk')));
      final opened = await openChanges(blob, key, space: 'f', epoch: 0);
      expect(opened.map((c) => c.toJson()), changes.map((c) => c.toJson()));
      await expectLater(openChanges(blob, randomBytes(32), space: 'f', epoch: 0), throwsA(isA<SealException>()));
      await expectLater(openChanges(blob, key, space: 'p', epoch: 0), throwsA(isA<SealException>()));
      await expectLater(openChanges(blob, key, space: 'f', epoch: 1), throwsA(isA<SealException>()));
      final again = await sealChanges(key, space: 'f', epoch: 0, changes: changes);
      expect(again, isNot(blob));
    });
  });

  group('relay tunnel protocol', () {
    test('frames round trip', () {
      final frame = decodeTunnelFrame(encodeTunnelFrame(TunnelOp.binary, 0xfffffffe, [1, 2, 3]))!;
      expect(frame.op, TunnelOp.binary);
      expect(frame.stream, 0xfffffffe);
      expect(frame.payload, [1, 2, 3]);
      expect(decodeTunnelFrame([9, 0, 0, 0, 1]), isNull);
      expect(decodeTunnelFrame([1, 0]), isNull);
    });

    test('tunnel auth checks the id and the signature', () async {
      final hubKeys = await DeviceKeys.generate();
      final forger = await DeviceKeys.generate();
      final hubId = await hubKeys.deviceId();
      const nonce = 'abc';
      final sig = await hubKeys.sign(tunnelAuthBytes(hubId, nonce));
      expect(await verifyTunnelAuth(hubId: hubId, nonce: nonce, pubkey: hubKeys.pubkey, sig: sig), isTrue);
      expect(await verifyTunnelAuth(hubId: hubId, nonce: 'abd', pubkey: hubKeys.pubkey, sig: sig), isFalse);
      final forged = await forger.sign(tunnelAuthBytes(hubId, nonce));
      expect(await verifyTunnelAuth(hubId: hubId, nonce: nonce, pubkey: forger.pubkey, sig: forged), isFalse);
      expect(await verifyTunnelAuth(hubId: hubId, nonce: nonce, pubkey: hubKeys.pubkey, sig: forged), isFalse);
    });

    test('relay URLs', () {
      final relay = Uri.parse('https://relay.den.family/base');
      expect(relayTunnelUri(relay, 'abcdefghijklmnop').toString(), 'wss://relay.den.family/base/tunnel/abcdefghijklmnop');
      expect(relayConnectUri(Uri.parse('http://localhost:47734'), 'abcdefghijklmnop').toString(),
          'ws://localhost:47734/connect/abcdefghijklmnop');
      expect(hubIdOfConnectUri(Uri.parse('wss://r/connect/abcdefghijklmnop')), 'abcdefghijklmnop');
      expect(hubIdOfConnectUri(Uri.parse('wss://r/ws')), isNull);
      expect(relayRendezvousUri(relay, 'ff' * 32, host: true).queryParameters['role'], 'host');
    });
  });
}
