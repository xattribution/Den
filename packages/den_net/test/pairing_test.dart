import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:den_net/io.dart';
import 'package:test/test.dart';

void main() {
  group('QR invites', () {
    late DeviceKeys founder;
    late DeviceKeys inviter;
    late DeviceKeys joiner;
    late Invite invite;

    setUpAll(() async {
      founder = await DeviceKeys.generate();
      inviter = await DeviceKeys.generate();
      joiner = await DeviceKeys.generate();
    });

    setUp(() async {
      invite = Invite.create(
        familyId: 'abcdefghijklmnop',
        founderPubkey: founder.pubkey,
        inviterDevice: await inviter.deviceId(),
        inviterPubkey: inviter.pubkey,
        hubs: [Uri.parse('ws://192.168.1.20:47733/ws'), Uri.parse('wss://den.example:47733/ws?a=1,2')],
        relay: Uri.parse('wss://relay.den.family'),
      );
    });

    test('round trips through the den://join URL', () async {
      final url = invite.toUrl();
      expect(url, startsWith('den://join?f=abcdefghijklmnop&fk='));
      for (final key in ['&d=', '&k=', '&s=', '&h=', '&r=', '&x=']) {
        expect(url, contains(key));
      }
      final parsed = await Invite.parse(url);
      expect(parsed.familyId, invite.familyId);
      expect(parsed.founderPubkey, founder.pubkey);
      expect(parsed.inviterDevice, await inviter.deviceId());
      expect(parsed.inviterPubkey, inviter.pubkey);
      expect(parsed.secret, invite.secret);
      expect(parsed.secret, hasLength(16));
      expect(parsed.hubs, invite.hubs);
      expect(parsed.relay, invite.relay);
      expect(parsed.expires, invite.expires);
    });

    test('works with no hubs and no relay', () async {
      final bare = Invite.create(
        familyId: 'f',
        founderPubkey: founder.pubkey,
        inviterDevice: await inviter.deviceId(),
        inviterPubkey: inviter.pubkey,
      );
      final parsed = await Invite.parse(bare.toUrl());
      expect(parsed.hubs, isEmpty);
      expect(parsed.relay, isNull);
    });

    test('the joiner proof checks out, and a bad HMAC is rejected', () async {
      final book = InviteBook()..add(invite);
      final scanned = await Invite.parse(invite.toUrl());
      final proof = await scanned.proofFor(joiner.pubkey);
      expect(await invite.checkProof(joiner.pubkey, proof), isTrue);

      // A proof for another key, a tampered proof, and garbage all fail.
      expect(await book.redeem(inviter.pubkey, proof), isNull);
      final tampered = b64d(proof)..[0] ^= 1;
      expect(await book.redeem(joiner.pubkey, b64e(tampered)), isNull);
      expect(await book.redeem(joiner.pubkey, 'not base64 !'), isNull);
      final guessed = Invite.create(
        familyId: invite.familyId,
        founderPubkey: founder.pubkey,
        inviterDevice: invite.inviterDevice,
        inviterPubkey: inviter.pubkey,
      );
      expect(await book.redeem(joiner.pubkey, await guessed.proofFor(joiner.pubkey)), isNull);

      // The real proof works once.
      expect(await book.redeem(joiner.pubkey, proof), same(invite));
      expect(await book.redeem(joiner.pubkey, proof), isNull);
    });

    test('expired invites fail to parse and are not redeemable', () async {
      final now = DateTime.utc(2026, 10, 17, 12);
      final shortLived = Invite.create(
        familyId: 'f',
        founderPubkey: founder.pubkey,
        inviterDevice: await inviter.deviceId(),
        inviterPubkey: inviter.pubkey,
        validFor: const Duration(minutes: 5),
        now: now,
      );
      await expectLater(
        Invite.parse(shortLived.toUrl(), now: now.add(const Duration(minutes: 6))),
        throwsFormatException,
      );
      expect(await Invite.parse(shortLived.toUrl(), now: now.add(const Duration(minutes: 4))), isNotNull);

      var clock = now;
      final book = InviteBook(now: () => clock)..add(shortLived);
      final proof = await shortLived.proofFor(joiner.pubkey);
      clock = now.add(const Duration(minutes: 6));
      expect(await book.redeem(joiner.pubkey, proof), isNull);
    });

    test('an invite whose device id does not match its key is rejected', () async {
      final forged = Invite(
        familyId: 'f',
        founderPubkey: founder.pubkey,
        inviterDevice: await joiner.deviceId(),
        inviterPubkey: inviter.pubkey,
        secret: randomBytes(16),
        expires: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      await expectLater(Invite.parse(forged.toUrl()), throwsFormatException);
    });

    test('malformed URLs are rejected', () {
      for (final url in [
        'https://example.com',
        'den://join?f=x',
        'den://join?f=x&fk=AAAA&d=y&k=AAAA&s=AAAA&x=1',
        invite.toUrl().replaceFirst(RegExp(r's=[^&]+'), 's=abc'),
        invite.toUrl().replaceFirst(RegExp(r'x=\d+'), 'x=soon'),
      ]) {
        expect(() => Invite.decode(url), throwsFormatException, reason: url);
      }
    });

    test('the rendezvous slot is derived from the secret', () async {
      final slot = await invite.rendezvousSlot();
      expect(slot, matches(relayKeyPattern));
      expect(await (await Invite.parse(invite.toUrl())).rendezvousSlot(), slot);
    });
  });

  group('spoken codes', () {
    test('are four words from the list', () {
      final code = CodeBook().issue();
      expect(code.words, hasLength(4));
      for (final w in code.words) {
        expect(wordList, contains(w));
      }
      expect(code.text.split(' '), code.words);
    });

    test('accept any case, separators and four-letter prefixes', () {
      expect(normalizeCode('Abandon  ABILITY able, about'), 'abandon ability able about');
      expect(normalizeCode('aban abil able abou'), 'abandon ability able about');
      expect(normalizeCode('zoo-zone-zero-zebra'), 'zoo zone zero zebra');
      expect(normalizeCode('abandon ability able'), isNull);
      expect(normalizeCode('abandon ability able notaword'), isNull);
      expect(normalizeCode('abandn ability able about'), isNull);
    });

    test('are used up by the right code', () {
      final book = CodeBook();
      final code = book.issue();
      expect(book.redeemTyped(code.text.toUpperCase()), same(code));
      expect(code.used, isTrue);
      expect(book.redeemTyped(code.text), isNull);
    });

    test('are burned after 5 wrong tries, counted per code', () {
      final book = CodeBook();
      final code = book.issue();
      final other = book.issue();
      final wrong = code.words.first == 'zoo' ? 'abandon abandon abandon abandon' : 'zoo zoo zoo zoo';
      for (var i = 0; i < 4; i++) {
        expect(book.redeemTyped(wrong), isNull);
      }
      expect(code.failures, 4);
      expect(other.failures, 4);
      expect(book.live, hasLength(2));
      // The fifth wrong try burns every live code; even the right words fail afterwards.
      expect(book.redeemTyped('not even words'), isNull);
      expect(book.live, isEmpty);
      expect(book.redeemTyped(code.text), isNull);
      expect(book.redeemTyped(other.text), isNull);
    });

    test('a fresh code is unaffected by failures before it was issued', () {
      final book = CodeBook();
      book.issue();
      for (var i = 0; i < 5; i++) {
        book.redeemTyped('zoo zoo zoo zoo');
      }
      final fresh = book.issue();
      expect(fresh.failures, 0);
      expect(book.redeemTyped(fresh.text), same(fresh));
    });

    test('expire after 10 minutes', () {
      var now = DateTime.utc(2026, 1, 1);
      final book = CodeBook(now: () => now);
      final code = book.issue();
      expect(code.expires, now.add(const Duration(minutes: 10)));
      now = now.add(const Duration(minutes: 9, seconds: 59));
      expect(book.live, hasLength(1));
      now = now.add(const Duration(seconds: 1));
      expect(book.live, isEmpty);
      expect(book.redeemTyped(code.text), isNull);
    });

    test('session proofs bind the code to the transcript and key', () async {
      final joiner = await DeviceKeys.generate();
      final host = await DeviceKeys.generate();
      final transcript = randomBytes(32);
      final book = CodeBook();
      final code = book.issue();
      final proof = await joinerCodeProof(code.text, transcript, joiner.pubkey);

      expect(await book.redeemProof(proof, randomBytes(32), joiner.pubkey), isNull);
      expect(await book.redeemProof(proof, transcript, host.pubkey), isNull);
      expect(code.failures, 2);
      expect(await book.redeemProof(proof, transcript, joiner.pubkey), same(code));

      final hostProof = await hostCodeProof(code.text, transcript, host.pubkey);
      expect(hostProof, isNot(await joinerCodeProof(code.text, transcript, host.pubkey)));
    });

    test('proof failures count toward the burn too', () async {
      final joiner = await DeviceKeys.generate();
      final book = CodeBook();
      final code = book.issue();
      for (var i = 0; i < 5; i++) {
        expect(await book.redeemProof(b64e(randomBytes(32)), randomBytes(32), joiner.pubkey), isNull);
      }
      final transcript = randomBytes(32);
      expect(await book.redeemProof(await joinerCodeProof(code.text, transcript, joiner.pubkey), transcript, joiner.pubkey),
          isNull);
    });

    test('are stretched with Argon2id before they name a slot or key a proof', () async {
      const code = 'zoo zone zero zebra';
      expect(codeStretchMemoryKiB, greaterThanOrEqualTo(4096));
      expect(codeStretchIterations, greaterThanOrEqualTo(3));
      final kdf = Argon2id(parallelism: 1, memory: codeStretchMemoryKiB, iterations: codeStretchIterations, hashLength: 32);
      final expected = await kdf.deriveKey(secretKey: SecretKey(utf8.encode(code)), nonce: utf8.encode('den/spoken-code/v2'));
      final stretched = await stretchCode('Zoo  ZONE zero zebr');
      expect(stretched, await expected.extractBytes());

      // Neither the slot nor a proof is a fast hash of the code anymore.
      String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fastSlot = hex((await Sha256().hash(utf8.encode('den/rendezvous/v1/code|$code'))).bytes);
      final slot = await codeRendezvousSlot(code);
      expect(slot, isNot(fastSlot));
      final mac = await Hmac.sha256().calculateMac(utf8.encode('den/rendezvous/v2/code'), secretKey: SecretKey(stretched));
      expect(slot, hex(mac.bytes));
      final joiner = await DeviceKeys.generate();
      final transcript = randomBytes(32);
      final proof = b64d(await joinerCodeProof(code, transcript, joiner.pubkey));
      final keyedByCode = await Hmac.sha256().calculateMac(
        [...utf8.encode('den/pair/v2/joiner'), 0, ...transcript, ...b64d(joiner.pubkey)],
        secretKey: SecretKey(utf8.encode(code)),
      );
      expect(proof, isNot(keyedByCode.bytes));
      final keyedByStretch = await Hmac.sha256().calculateMac(
        [...utf8.encode('den/pair/v2/joiner'), 0, ...transcript, ...b64d(joiner.pubkey)],
        secretKey: SecretKey(stretched),
      );
      expect(proof, keyedByStretch.bytes);
    });

    test('rendezvous slots depend only on the normalized code', () async {
      expect(await codeRendezvousSlot('Zoo zone zero zebra'), await codeRendezvousSlot('zoo zone zero zebr'));
      expect(await codeRendezvousSlot('zoo zone zero zebra'), isNot(await codeRendezvousSlot('zoo zone zero zone')));
      expect(await codeRendezvousSlot('zoo zone zero zebra'), matches(relayKeyPattern));
    });
  });

  group('matching words', () {
    test('three words from the list, stable for one transcript', () async {
      final t = randomBytes(32);
      final words = await matchingWords(t);
      expect(words, hasLength(3));
      expect(await matchingWords(t), words);
      expect(await matchingWords(randomBytes(32)), isNot(words));
    });
  });

  group('LAN discovery', () {
    test('parses TXT records the hub advertises', () {
      final txt = parseServiceTxt(['id=abcdefghijklmnop', 'f=qrstuvwxyz234567', 'v=1', 'flag', ''].join('\n'));
      expect(txt, {'id': 'abcdefghijklmnop', 'f': 'qrstuvwxyz234567', 'v': '1', 'flag': ''});
      final hub = DiscoveredHub(
        instance: 'Den hub._den._tcp.local',
        host: 'nas.local',
        port: 47733,
        addresses: [InternetAddress('192.168.1.20')],
        deviceId: txt['id'],
      );
      expect(hub.syncUri.toString(), 'ws://192.168.1.20:47733/ws');
    });
  });
}
