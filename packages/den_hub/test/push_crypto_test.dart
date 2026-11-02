import 'dart:convert';

import 'package:den_hub/src/push/web_push_crypto.dart';
import 'package:test/test.dart';

List<int> hex(String text) => [for (var i = 0; i < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16)];

void main() {
  test('encrypts as RFC 8291 section 5 and appendix A show', () {
    final body = encryptForPush(
      unb64url('V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24'),
      uaPublic: unb64url('BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4'),
      authSecret: unb64url('BTBZMqHH6r4Tts7J_aSIgg'),
      serverPrivate: unb64url('yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw'),
      salt: unb64url('DGv6ra1nlYgDCS1FRnbzlw'),
    );
    expect(
      b64url(body),
      'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml'
      'mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT'
      'pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN',
    );
  });

  test('a fresh key and salt every time', () {
    final ua = unb64url('BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4');
    final auth = unb64url('BTBZMqHH6r4Tts7J_aSIgg');
    final a = encryptForPush(utf8.encode('hello'), uaPublic: ua, authSecret: auth);
    final b = encryptForPush(utf8.encode('hello'), uaPublic: ua, authSecret: auth);
    expect(a.length, 16 + 4 + 1 + 65 + 5 + 1 + 16);
    expect(b64url(a), isNot(b64url(b)));
  });

  test('refuses a key that is not a P-256 point', () {
    expect(
      () => encryptForPush([1], uaPublic: List.filled(65, 4), authSecret: List.filled(16, 0)),
      throwsA(anything),
    );
  });

  test('signs ES256 deterministically, as RFC 6979 A.2.5 shows for P-256 with SHA-256', () {
    final keys = VapidKeys.fromPrivate(hex('C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721'));
    expect(
      keys.publicKey,
      hex('04'
          '60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6'
          '7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299'),
    );
    expect(
      keys.sign(utf8.encode('sample')),
      hex('EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716'
          'F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8'),
    );
    expect(
      keys.sign(utf8.encode('test')),
      hex('F1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367'
          '019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083'),
    );
  });

  test('VAPID authorization: a JWT for the push service, signed with the key it names (RFC 8292)', () {
    final keys = VapidKeys.generate();
    final expires = DateTime.utc(2026, 10, 28, 12);
    final header = keys.authorization(
      Uri.parse('https://web.push.apple.com/QGuQyavXutnMH-2Ff4c?x=1'),
      subject: 'https://den.example.com',
      expires: expires,
    );
    final match = RegExp(r'^vapid t=([^,]+), k=(.+)$').firstMatch(header)!;
    expect(unb64url(match.group(2)!), keys.publicKey);
    final parts = match.group(1)!.split('.');
    expect(parts, hasLength(3));
    expect(jsonDecode(utf8.decode(unb64url(parts[0]))), {'typ': 'JWT', 'alg': 'ES256'});
    expect(jsonDecode(utf8.decode(unb64url(parts[1]))), {
      'aud': 'https://web.push.apple.com',
      'exp': expires.millisecondsSinceEpoch ~/ 1000,
      'sub': 'https://den.example.com',
    });
    final signature = unb64url(parts[2]);
    expect(keys.verify(ascii.encode('${parts[0]}.${parts[1]}'), signature), isTrue);
    expect(keys.verify(ascii.encode('${parts[0]}.x'), signature), isFalse);

    final again = VapidKeys.fromPrivate(keys.privateKey);
    expect(again.publicKey, keys.publicKey, reason: 'the private key alone restores the pair');
  });
}
