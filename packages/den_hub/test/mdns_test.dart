import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:den_hub/den_hub.dart';
import 'package:den_net/io.dart' show parseServiceTxt;
// The packet codec of package:multicast_dns, the client den_net's discoverHubs uses, checks the
// responder's bytes from the other side.
// ignore: implementation_imports
import 'package:multicast_dns/src/packet.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:test/test.dart';

void main() {
  const advert = MdnsAdvert(
    instance: 'Kitchen hub',
    host: 'den-abcdefgh',
    port: 47733,
    txt: {'id': 'abcdefghijklmnop', 'name': 'Kitchen hub', 'version': '0.1.0', 'api': '1', 'f': 'familyid12345678'},
  );
  final addresses = [InternetAddress('192.168.1.20')];

  test('records encode and decode, names, TXT and addresses intact', () {
    final message = DnsMessage(response: true, answers: advert.records(addresses));
    final back = DnsMessage.decode(message.encode());
    expect(back.response, isTrue);
    expect(back.answers.map((r) => r.type), [DnsType.ptr, DnsType.srv, DnsType.txt, DnsType.a]);
    expect(back.answers[0].target, 'Kitchen hub._den._tcp.local');
    expect(back.answers[1].target, 'den-abcdefgh.local');
    expect(back.answers[1].port, 47733);
    expect(back.answers[1].flush, isTrue);
    expect(back.answers[2].txt, advert.txt);
    expect(back.answers[3].address.address, '192.168.1.20');
    final goodbye = DnsMessage.decode(DnsMessage(response: true, answers: advert.records(addresses, goodbye: true)).encode());
    expect(goodbye.answers.every((r) => r.ttl == 0), isTrue);
  });

  test('answers a PTR query the way multicast_dns reads it, TXT keys as discoverHubs expects', () {
    final query = DnsMessage.decode(encodeMDnsQuery('_den._tcp.local', type: ResourceRecordType.serverPointer));
    expect(query.questions.single.name, '_den._tcp.local');
    final reply = advert.answer(query, addresses)!;
    final records = decodeMDnsResponse(reply.encode())!;
    final ptr = records.whereType<PtrResourceRecord>().single;
    expect(ptr.domainName, 'Kitchen hub._den._tcp.local');
    final srv = records.whereType<SrvResourceRecord>().single;
    expect((srv.target, srv.port), ('den-abcdefgh.local', 47733));
    final txt = parseServiceTxt(records.whereType<TxtResourceRecord>().single.text);
    expect(txt, {'id': 'abcdefghijklmnop', 'name': 'Kitchen hub', 'version': '0.1.0', 'api': '1', 'f': 'familyid12345678'});
    expect(records.whereType<IPAddressResourceRecord>().single.address.address, '192.168.1.20');
  });

  test('answers SRV, TXT and A questions, ignores others, and echoes legacy unicast queries', () {
    DnsMessage ask(String name, int type, {int id = 0}) => DnsMessage(id: id, questions: [DnsQuestion(name, type)]);
    expect(advert.answer(ask('Kitchen hub._den._tcp.local', DnsType.srv), addresses)!.answers.single.type, DnsType.srv);
    expect(advert.answer(ask('kitchen hub._den._tcp.local', DnsType.txt), addresses)!.answers.single.type, DnsType.txt);
    expect(advert.answer(ask('den-abcdefgh.local', DnsType.a), addresses)!.answers.single.type, DnsType.a);
    expect(advert.answer(ask('_other._tcp.local', DnsType.ptr), addresses), isNull);
    final legacy = advert.answer(ask('_den._tcp.local', DnsType.ptr, id: 4242), addresses, legacy: true)!;
    expect(legacy.id, 4242);
    expect(legacy.questions.single.name, '_den._tcp.local');
    final services = advert.answer(ask('_services._dns-sd._udp.local', DnsType.ptr), addresses)!;
    expect(services.answers.single.target, '_den._tcp.local');
  });

  test('compressed names in incoming messages are expanded', () {
    final bytes = [
      0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0,
      4, ...'_den'.codeUnits, 4, ...'_tcp'.codeUnits, 5, ...'local'.codeUnits, 0,
      0, 12, 0, 1, 0, 0, 0, 120, 0, 5,
      2, ...'hi'.codeUnits, 0xc0, 12,
    ];
    final m = DnsMessage.decode(bytes);
    expect(m.answers.single.name, '_den._tcp.local');
    expect(m.answers.single.target, 'hi._den._tcp.local');
    expect(() => DnsMessage.decode([1, 2, 3]), throwsFormatException);
  });

  test('a malformed packet is a FormatException, never a crash', () async {
    List<int> answer(int type, List<int> data) => [
          0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0,
          2, ...'hi'.codeUnits, 5, ...'local'.codeUnits, 0,
          0, type, 0, 1, 0, 0, 0, 120, 0, data.length, ...data,
        ];
    final bad = [
      answer(DnsType.srv, [0, 0]),
      answer(DnsType.srv, [0, 0, 0, 0, 0, 80]),
      answer(DnsType.a, [192, 168, 1]),
      answer(DnsType.aaaa, [1, 2, 3, 4]),
      answer(DnsType.ptr, []),
      [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0x41, 0x61, 0, 0, 1, 0, 1],
    ];
    for (final packet in bad) {
      expect(() => DnsMessage.decode(packet), throwsFormatException, reason: '$packet');
    }
    final valid = DnsMessage(response: true, answers: advert.records(addresses)).encode();
    final random = Random(47733);
    for (var i = 0; i < 5000; i++) {
      final mutated = List<int>.of(valid);
      for (var flips = random.nextInt(6) + 1; flips > 0; flips--) {
        mutated[random.nextInt(mutated.length)] = random.nextInt(256);
      }
      final cut = random.nextBool() ? mutated.sublist(0, random.nextInt(mutated.length)) : mutated;
      try {
        DnsMessage.decode(cut);
      } on FormatException {
        // Refused, as it should be.
      }
    }
    final responder = MdnsResponder(advert);
    for (final packet in [...bad, valid.sublist(0, 30)]) {
      await responder.handle(Datagram(Uint8List.fromList(packet), InternetAddress.loopbackIPv4, 5353));
    }
  });

  test('a responder that can\'t bind leaves the hub running', () async {
    final responder = MdnsResponder(advert);
    await responder.start();
    await responder.stop();
    expect(responder.running, isFalse);
  });
}
