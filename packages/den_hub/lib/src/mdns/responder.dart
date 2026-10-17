import 'dart:async';
import 'dart:io';

import '../log.dart';
import 'dns.dart';

/// The DNS-SD service type hubs advertise.
const String denServiceName = '_den._tcp.local';

final InternetAddress _group = InternetAddress('224.0.0.251');
const int _mdnsPort = 5353;

/// What the hub advertises.
class MdnsAdvert {
  /// Creates an advert.
  const MdnsAdvert({required this.instance, required this.host, required this.port, required this.txt});

  /// Service instance name (the hub's name); dots become spaces so it stays one label.
  final String instance;

  /// Host name without `.local` (`den-abcd1234`).
  final String host;

  /// The hub's port.
  final int port;

  /// TXT keys.
  final Map<String, String> txt;

  /// `<instance>._den._tcp.local`.
  String get instanceName => '${instance.replaceAll('.', ' ')}.$denServiceName';

  /// `<host>.local`.
  String get hostName => '$host.local';

  /// The PTR, SRV, TXT and A records, with [ttl] scaled (0 for goodbye).
  List<DnsRecord> records(List<InternetAddress> addresses, {bool goodbye = false}) {
    final all = [
      DnsRecord.ptr(denServiceName, instanceName),
      DnsRecord.srv(instanceName, hostName, port),
      DnsRecord.txt(instanceName, txt),
      for (final a in addresses) DnsRecord.a(hostName, a),
    ];
    return goodbye ? [for (final r in all) r.withTtl(0)] : all;
  }

  /// The response to [query], or null when it asks about nothing of ours. Answers PTR for the
  /// service type (and the DNS-SD service list), SRV and TXT for the instance and A for the
  /// host, with the related records as additional data.
  DnsMessage? answer(DnsMessage query, List<InternetAddress> addresses, {bool legacy = false}) {
    if (query.response) return null;
    final answers = <DnsRecord>[];
    final all = records(addresses);
    bool want(DnsQuestion q, int type) => q.type == type || q.type == DnsType.any;
    for (final q in query.questions) {
      final name = q.name.toLowerCase();
      if (name == denServiceName && want(q, DnsType.ptr)) answers.add(all[0]);
      if (name == '_services._dns-sd._udp.local' && want(q, DnsType.ptr)) {
        answers.add(DnsRecord.ptr('_services._dns-sd._udp.local', denServiceName));
      }
      if (name == instanceName.toLowerCase()) {
        if (want(q, DnsType.srv)) answers.add(all[1]);
        if (want(q, DnsType.txt)) answers.add(all[2]);
      }
      if (name == hostName.toLowerCase() && want(q, DnsType.a)) answers.addAll(all.skip(3));
    }
    if (answers.isEmpty) return null;
    final additional = [for (final r in all) if (!answers.contains(r)) r];
    return DnsMessage(
      id: legacy ? query.id : 0,
      response: true,
      questions: legacy ? query.questions : const [],
      answers: answers,
      additional: additional,
    );
  }
}

/// A small mDNS responder on a [RawDatagramSocket]: joins 224.0.0.251:5353 on every IPv4
/// interface it can, announces on start, answers queries, and says goodbye on stop. Binding
/// failures are logged and leave the hub running without LAN discovery.
class MdnsResponder {
  /// Creates a responder for [advert].
  MdnsResponder(this.advert, {HubLog? log}) : _log = log ?? HubLog.silent();

  /// What is advertised; [update] replaces it.
  MdnsAdvert advert;

  final HubLog _log;
  RawDatagramSocket? _socket;
  List<NetworkInterface> _interfaces = const [];
  Timer? _again;

  /// Whether the socket is open.
  bool get running => _socket != null;

  Future<List<InternetAddress>> _addresses() async => [
        for (final i in _interfaces)
          for (final a in i.addresses)
            if (a.type == InternetAddressType.IPv4 && !a.isLoopback && !a.isLinkLocal) a,
      ];

  /// Opens the socket and announces.
  Future<void> start() async {
    try {
      _interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _mdnsPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows && !Platform.isAndroid,
      );
      socket.multicastLoopback = true;
      var joined = 0;
      for (final i in _interfaces) {
        try {
          socket.joinMulticast(_group, i);
          joined++;
        } on Object {
          _log.debug('mDNS couldn\'t join on an interface');
        }
      }
      if (joined == 0) socket.joinMulticast(_group);
      socket.listen((event) {
        if (event == RawSocketEvent.read) _read(socket);
      });
      _socket = socket;
      await _announce();
      _again = Timer(const Duration(seconds: 1), () => unawaited(_announce()));
      _log.info('Advertising _den._tcp on the local network');
    } on Object catch (e) {
      _log.warn('mDNS isn\'t available (${e.runtimeType}); the hub runs without LAN discovery');
    }
  }

  void _read(RawDatagramSocket socket) {
    final datagram = socket.receive();
    if (datagram == null) return;
    final DnsMessage query;
    try {
      query = DnsMessage.decode(datagram.data);
    } on FormatException {
      return;
    }
    unawaited(_addresses().then((addresses) {
      final legacy = datagram.port != _mdnsPort;
      if (query.questions.isNotEmpty) _log.debug('mDNS query for ${query.questions.first.name}${legacy ? ' (unicast)' : ''}');
      final reply = advert.answer(query, addresses, legacy: legacy);
      if (reply == null) return;
      final unicast = legacy || query.questions.every((q) => q.unicast);
      _send(reply, unicast ? datagram.address : _group, unicast ? datagram.port : _mdnsPort);
    }));
  }

  void _send(DnsMessage message, InternetAddress to, int port) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(message.encode(), to, port);
    } on Object {
      _log.debug('mDNS send failed');
    }
  }

  Future<void> _announce({bool goodbye = false}) async {
    final addresses = await _addresses();
    _send(DnsMessage(response: true, answers: advert.records(addresses, goodbye: goodbye)), _group, _mdnsPort);
  }

  /// Replaces the advert (a new name, or the family id after joining) and announces it.
  Future<void> update(MdnsAdvert next) async {
    if (_socket != null && next.instanceName != advert.instanceName) await _announce(goodbye: true);
    advert = next;
    if (_socket != null) await _announce();
  }

  /// Says goodbye and closes the socket.
  Future<void> stop() async {
    _again?.cancel();
    if (_socket == null) return;
    await _announce(goodbye: true);
    _socket?.close();
    _socket = null;
  }
}
