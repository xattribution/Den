import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// DNS record types the responder uses.
abstract final class DnsType {
  /// IPv4 address.
  static const int a = 1;

  /// Pointer.
  static const int ptr = 12;

  /// Text.
  static const int txt = 16;

  /// IPv6 address.
  static const int aaaa = 28;

  /// Service.
  static const int srv = 33;

  /// Any type (queries).
  static const int any = 255;
}

/// A question in a DNS message.
class DnsQuestion {
  /// Creates a question.
  const DnsQuestion(this.name, this.type, {this.unicast = false});

  /// Name asked about (no trailing dot).
  final String name;

  /// Record type asked for.
  final int type;

  /// The QU bit: the asker wants a unicast answer.
  final bool unicast;
}

/// A resource record.
class DnsRecord {
  /// Creates a record with raw [data].
  DnsRecord(this.name, this.type, this.ttl, this.data, {this.flush = false});

  /// A PTR record.
  factory DnsRecord.ptr(String name, String target, {int ttl = 4500}) => DnsRecord(name, DnsType.ptr, ttl, encodeName(target));

  /// An SRV record.
  factory DnsRecord.srv(String name, String target, int port, {int ttl = 120}) => DnsRecord(
        name,
        DnsType.srv,
        ttl,
        Uint8List.fromList([0, 0, 0, 0, port >> 8, port & 0xff, ...encodeName(target)]),
        flush: true,
      );

  /// A TXT record of `key=value` strings.
  factory DnsRecord.txt(String name, Map<String, String> values, {int ttl = 4500}) {
    final out = BytesBuilder();
    for (final e in values.entries) {
      final bytes = utf8.encode('${e.key}=${e.value}');
      out
        ..addByte(bytes.length > 255 ? 255 : bytes.length)
        ..add(bytes.length > 255 ? bytes.sublist(0, 255) : bytes);
    }
    if (values.isEmpty) out.addByte(0);
    return DnsRecord(name, DnsType.txt, ttl, out.takeBytes(), flush: true);
  }

  /// An A record.
  factory DnsRecord.a(String name, InternetAddress address, {int ttl = 120}) =>
      DnsRecord(name, DnsType.a, ttl, Uint8List.fromList(address.rawAddress), flush: true);

  /// Owner name (no trailing dot).
  final String name;

  /// Record type.
  final int type;

  /// Seconds to keep it; 0 says goodbye.
  final int ttl;

  /// RDATA, with names uncompressed.
  final Uint8List data;

  /// The cache-flush bit (unique records).
  final bool flush;

  /// A copy with another TTL.
  DnsRecord withTtl(int ttl) => DnsRecord(name, type, ttl, data, flush: flush);

  /// The PTR or SRV target name.
  String get target => type == DnsType.srv ? decodeName(data, 6).$1 : decodeName(data, 0).$1;

  /// The SRV port.
  int get port => (data[4] << 8) | data[5];

  /// TXT values.
  Map<String, String> get txt {
    final out = <String, String>{};
    var i = 0;
    while (i < data.length) {
      final n = data[i++];
      if (n == 0 || i + n > data.length) {
        i += n;
        continue;
      }
      final s = utf8.decode(data.sublist(i, i + n), allowMalformed: true);
      i += n;
      final eq = s.indexOf('=');
      if (eq > 0) out[s.substring(0, eq).toLowerCase()] = s.substring(eq + 1);
    }
    return out;
  }

  /// The A record's address.
  InternetAddress get address => InternetAddress.fromRawAddress(data);
}

/// A DNS message (RFC 1035) as mDNS uses it.
class DnsMessage {
  /// Creates a message.
  DnsMessage({
    this.id = 0,
    this.response = false,
    this.questions = const [],
    this.answers = const [],
    this.additional = const [],
  });

  /// Message id (0 for multicast).
  final int id;

  /// A response (QR bit, authoritative).
  final bool response;

  /// Questions.
  final List<DnsQuestion> questions;

  /// Answers.
  final List<DnsRecord> answers;

  /// Additional records.
  final List<DnsRecord> additional;

  /// The wire bytes.
  Uint8List encode() {
    final out = BytesBuilder();
    void u16(int v) => out.add([(v >> 8) & 0xff, v & 0xff]);
    u16(id);
    u16(response ? 0x8400 : 0);
    u16(questions.length);
    u16(answers.length);
    u16(0);
    u16(additional.length);
    for (final q in questions) {
      out.add(encodeName(q.name));
      u16(q.type);
      u16(q.unicast ? 0x8001 : 1);
    }
    for (final r in [...answers, ...additional]) {
      out.add(encodeName(r.name));
      u16(r.type);
      u16(r.flush ? 0x8001 : 1);
      out.add([(r.ttl >> 24) & 0xff, (r.ttl >> 16) & 0xff, (r.ttl >> 8) & 0xff, r.ttl & 0xff]);
      u16(r.data.length);
      out.add(r.data);
    }
    return out.takeBytes();
  }

  /// Reads a message, expanding compressed names in RDATA. Throws [FormatException].
  static DnsMessage decode(List<int> bytes) {
    final b = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (b.length < 12) throw const FormatException('short DNS message');
    int u16(int at) => (b[at] << 8) | b[at + 1];
    final flags = u16(2);
    final counts = [u16(4), u16(6), u16(8), u16(10)];
    var i = 12;
    final questions = <DnsQuestion>[];
    for (var n = 0; n < counts[0]; n++) {
      final (name, next) = decodeName(b, i);
      if (next + 4 > b.length) throw const FormatException('truncated question');
      questions.add(DnsQuestion(name, u16(next), unicast: (u16(next + 2) & 0x8000) != 0));
      i = next + 4;
    }
    final records = <DnsRecord>[];
    for (var n = 0; n < counts[1] + counts[2] + counts[3]; n++) {
      final (name, next) = decodeName(b, i);
      if (next + 10 > b.length) throw const FormatException('truncated record');
      final type = u16(next), cls = u16(next + 2);
      final ttl = (b[next + 4] << 24) | (b[next + 5] << 16) | (b[next + 6] << 8) | b[next + 7];
      final length = u16(next + 8);
      final start = next + 10;
      if (start + length > b.length) throw const FormatException('truncated data');
      var data = Uint8List.sublistView(b, start, start + length);
      if (type == DnsType.ptr) data = encodeName(decodeName(b, start).$1);
      if (type == DnsType.srv) data = Uint8List.fromList([...data.sublist(0, 6), ...encodeName(decodeName(b, start + 6).$1)]);
      records.add(DnsRecord(name, type, ttl, Uint8List.fromList(data), flush: (cls & 0x8000) != 0));
      i = start + length;
    }
    return DnsMessage(
      id: u16(0),
      response: (flags & 0x8000) != 0,
      questions: questions,
      answers: records.take(counts[1]).toList(),
      additional: records.skip(counts[1] + counts[2]).toList(),
    );
  }
}

/// A name as DNS labels, uncompressed.
Uint8List encodeName(String name) {
  final out = BytesBuilder();
  for (final label in name.split('.').where((l) => l.isNotEmpty)) {
    final bytes = utf8.encode(label);
    final n = bytes.length > 63 ? 63 : bytes.length;
    out
      ..addByte(n)
      ..add(bytes.sublist(0, n));
  }
  out.addByte(0);
  return out.takeBytes();
}

/// Reads a possibly compressed name at [offset]; returns it and the offset after it.
(String, int) decodeName(List<int> b, int offset) {
  final labels = <String>[];
  var i = offset;
  int? end;
  var jumps = 0;
  while (true) {
    if (i >= b.length) throw const FormatException('name runs past the message');
    final n = b[i];
    if (n == 0) {
      end ??= i + 1;
      break;
    }
    if ((n & 0xc0) == 0xc0) {
      if (i + 1 >= b.length || ++jumps > 20) throw const FormatException('bad name pointer');
      end ??= i + 2;
      i = ((n & 0x3f) << 8) | b[i + 1];
      continue;
    }
    if (i + 1 + n > b.length) throw const FormatException('label runs past the message');
    labels.add(utf8.decode(b.sublist(i + 1, i + 1 + n), allowMalformed: true));
    i += 1 + n;
  }
  return (labels.join('.'), end);
}
