/// Finding the NAS on the home network: an mDNS question for `_smb._tcp.local` (every Synology,
/// QNAP, TrueNAS, Unraid, a Mac or Linux box sharing files answers it), from an ephemeral port so
/// answers come straight back to the hub (RFC 6762, "one-shot" queries) and nothing else on the
/// server needs port 5353. A NAS that doesn't advertise is typed in by name or address instead.
library;

import 'dart:async';
import 'dart:io';

import '../mdns/dns.dart';

/// A NAS that answered: what it calls itself and where it is.
class FoundNas {
  /// [name] at [host] (an address, or a `.local` name).
  const FoundNas({required this.name, required this.host});

  /// What it calls itself ("Family NAS").
  final String name;

  /// Where to reach it: its address when it said one, else its `.local` name.
  final String host;

  /// As an answer says it.
  Map<String, Object?> toJson() => {'name': name, 'host': host};
}

/// Finds the NASes on the network: [MdnsNasFinder], or a fake in tests.
abstract interface class NasFinder {
  /// The NASes that answer within [wait].
  Future<List<FoundNas>> find({Duration wait = const Duration(seconds: 3)});
}

/// [NasFinder] by mDNS.
class MdnsNasFinder implements NasFinder {
  /// Finds NASes on every IPv4 interface.
  const MdnsNasFinder();

  static const String _service = '_smb._tcp.local';

  @override
  Future<List<FoundNas>> find({Duration wait = const Duration(seconds: 3)}) async {
    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } on SocketException {
      return const [];
    }
    final instances = <String>{};
    final targets = <String, String>{}; // instance -> host name
    final addresses = <String, String>{}; // host name -> address
    void take(DnsMessage m) {
      for (final r in [...m.answers, ...m.additional]) {
        try {
          if (r.type == DnsType.ptr && r.name.toLowerCase() == _service) instances.add(r.target);
          if (r.type == DnsType.srv) targets[r.name] = r.target;
          if (r.type == DnsType.a && r.data.length == 4) {
            addresses[r.name.toLowerCase()] = InternetAddress.fromRawAddress(r.data).address;
          }
        } on Object {
          // A record that doesn't read: skipped.
        }
      }
    }

    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null) return;
      try {
        take(DnsMessage.decode(d.data));
      } on FormatException {
        // Anyone on the network can send a packet; one that doesn't read is ignored.
      }
    });
    final query = DnsMessage(questions: [const DnsQuestion(_service, DnsType.ptr, unicast: true)]).encode();
    final group = InternetAddress('224.0.0.251');
    try {
      socket.send(query, group, 5353);
      await Future<void>.delayed(wait ~/ 2);
      socket.send(query, group, 5353);
      await Future<void>.delayed(wait ~/ 2);
    } on SocketException {
      // No multicast route: nothing found.
    } finally {
      await sub.cancel();
      socket.close();
    }
    final out = <String, FoundNas>{};
    for (final instance in instances) {
      final label = instance.toLowerCase().endsWith('.$_service') ? instance.substring(0, instance.length - _service.length - 1) : instance;
      final target = targets[instance];
      final host = target == null ? null : (addresses[target.toLowerCase()] ?? target);
      if (host == null) continue;
      out.putIfAbsent(host, () => FoundNas(name: label, host: host));
    }
    return out.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }
}
