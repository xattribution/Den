import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../input.dart';
import '../reader.dart';

/// Signs a request to the family's hub with this device's key (den_net's `DeviceRequest`):
/// returns the headers to send.
typedef RequestSigner = Future<Map<String, String>> Function(String method, Uri url, List<int> body);

/// The kinds of reader a hub can run for the family.
enum HubReaderKind { none, claude, home }

/// The reader a family set up on its hub, as the hub reports it. The Claude key never leaves
/// the hub; [keySaved] says whether one is there.
class HubReaderStatus {
  const HubReaderStatus({
    this.kind = HubReaderKind.none,
    this.reader,
    this.deviceFirst = true,
    this.model,
    this.address,
    this.keySaved = false,
  });

  static const none = HubReaderStatus();

  final HubReaderKind kind;

  /// What the reader is, as devices show it; null when the hub has none.
  final ReaderInfo? reader;

  /// Whether each device reads on its own first and asks the hub only for what it can't read.
  final bool deviceFirst;

  /// The Claude model, or the home model's name.
  final String? model;

  /// The home model's address, as the hub reaches it.
  final String? address;
  final bool keySaved;

  bool get ready => kind != HubReaderKind.none && reader != null;

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'reader': reader?.toJson(),
        'device_first': deviceFirst,
        'model': model,
        'address': address,
        'key_saved': keySaved,
      };

  static HubReaderStatus fromJson(Object? raw) {
    if (raw is! Map) return none;
    return HubReaderStatus(
      kind: HubReaderKind.values.asNameMap()[raw['kind']] ?? HubReaderKind.none,
      reader: ReaderInfo.fromJson(raw['reader']),
      deviceFirst: raw['device_first'] != false,
      model: raw['model'] as String?,
      address: raw['address'] as String?,
      keySaved: raw['key_saved'] == true,
    );
  }
}

/// What a parent asks the hub to read with. A null [key] keeps the key the hub already has.
class HubReaderSetup {
  const HubReaderSetup({required this.kind, this.key, this.model, this.address, this.deviceFirst = true});
  final HubReaderKind kind;
  final String? key;
  final String? model;
  final String? address;
  final bool deviceFirst;

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'key': ?key,
        'model': ?model,
        'address': ?address,
        'device_first': deviceFirst,
      };
}

/// Talks to the hub's capture endpoints (`/api/v1/capture/...`), signing every request with
/// this device's key. Tries the hub's addresses in order and remembers the one that answered.
class HubCaptureClient {
  HubCaptureClient({required this.bases, required this.sign, http.Client? client}) : _http = client ?? http.Client();

  /// The hub's HTTP base addresses, best first.
  final FutureOr<List<Uri>> Function() bases;
  final RequestSigner sign;
  final http.Client _http;
  Uri? _last;

  /// The hub's reader, or null when no hub answers.
  Future<HubReaderStatus?> status() async {
    final r = await _send('GET', '/api/v1/capture/reader', null, timeout: const Duration(seconds: 4));
    return r == null ? null : HubReaderStatus.fromJson(r);
  }

  /// Sets the hub's reader; parents only. Throws [ReaderException] with the hub's reason.
  Future<HubReaderStatus> configure(HubReaderSetup setup) async {
    final r = await _send('PUT', '/api/v1/capture/reader', setup.toJson(), timeout: const Duration(seconds: 15));
    if (r == null) throw const ReaderException('Couldn\'t reach the hub. Try again at home.', retry: true);
    return HubReaderStatus.fromJson(r);
  }

  /// The hub's reading of [input]: `{wire, reader}`.
  Future<Map<String, Object?>> read(CaptureInput input, {Duration timeout = const Duration(minutes: 3)}) async {
    final r = await _send('POST', '/api/v1/capture/read', input.toJson(), timeout: timeout);
    if (r == null) throw const ReaderException('Couldn\'t reach the hub to read that.', retry: true);
    return r;
  }

  /// Sends a signed request to the first base that answers. Null when none does; throws
  /// [ReaderException] when one answers with an error.
  Future<Map<String, Object?>?> _send(String method, String path, Object? body, {required Duration timeout}) async {
    final all = await bases();
    final ordered = [?_last, for (final b in all) if (b != _last) b];
    final bytes = body == null ? const <int>[] : utf8.encode(jsonEncode(body));
    for (final base in ordered) {
      final url = base.replace(path: path);
      http.Response response;
      try {
        final headers = await sign(method, url, bytes);
        final request = http.Request(method, url)
          ..headers.addAll(headers)
          ..headers['content-type'] = 'application/json';
        if (body != null) request.bodyBytes = bytes;
        response = await http.Response.fromStream(await _http.send(request).timeout(timeout)).timeout(timeout);
      } on TimeoutException {
        if (method == 'POST') throw const ReaderException('The hub took too long to read that.', retry: true);
        continue;
      } on Object {
        continue;
      }
      _last = base;
      Map<String, Object?> json;
      try {
        json = Map<String, Object?>.from(jsonDecode(utf8.decode(response.bodyBytes)) as Map);
      } on Object {
        json = const {};
      }
      if (response.statusCode >= 200 && response.statusCode < 300) return json;
      final error = json['error'] is Map ? Map<String, Object?>.from(json['error']! as Map) : const <String, Object?>{};
      final details = error['details'] is Map ? Map<String, Object?>.from(error['details']! as Map) : const <String, Object?>{};
      // The hub's limits, in words that say what to do (docs/hub-api.md, "Errors").
      final (message, retry) = switch ((response.statusCode, error['code'])) {
        (429, 'rate_limited') => ('Too many tries from here. Wait a few minutes, then try again.', true),
        (429, 'daily_limit') => (error['message'] as String? ?? 'That\'s all Den can read for you today.', false),
        (429, _) => ('The hub is busy reading other things. Try again in a moment.', true),
        (408, _) => ('The connection was too slow to send that to the hub. Try again on a better connection.', true),
        (413, _) => ("That's too large for the hub to read. Share a smaller photo or file.", false),
        _ => (error['message'] as String? ?? 'The hub refused that (${response.statusCode}).', details['retry'] == true),
      };
      throw ReaderException(message, retry: retry);
    }
    return null;
  }
}

/// The reader a parent set up on the family's hub, used by every device: what's shared goes to
/// the hub, which reads it with Claude or a model at home and sends back the same JSON any reader
/// does. The device resolves, checks and writes it as its own acting member.
class HubReader implements CaptureReader {
  HubReader(this.client, {this.cacheFor = const Duration(minutes: 1), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final HubCaptureClient client;
  final Duration cacheFor;
  final DateTime Function() _clock;
  HubReaderStatus? _status;
  DateTime? _checked;

  /// What the hub said last, or null before the first check.
  HubReaderStatus? get status => _status;

  @override
  ReaderInfo get info {
    final r = _status?.reader;
    if (r == null) {
      return const ReaderInfo(id: 'hub', name: 'The hub', place: ReaderPlace.home, inputs: {ReaderInput.text});
    }
    return ReaderInfo(id: 'hub', name: '${r.name} on the hub', place: r.place, inputs: r.inputs, historyName: r.historyName);
  }

  /// Asks the hub what it reads with, at most once a [cacheFor].
  Future<HubReaderStatus?> refresh({bool force = false}) async {
    final now = _clock();
    if (!force && _checked != null && now.difference(_checked!) < cacheFor) return _status;
    _checked = now;
    try {
      _status = await client.status();
    } on ReaderException {
      _status = null;
    }
    return _status;
  }

  @override
  Future<bool> available() async => (await refresh())?.ready ?? false;

  @override
  Future<Map<String, Object?>> read(ReadRequest request) async {
    final answer = await client.read(request.input);
    final wire = answer['wire'];
    if (wire is! Map) throw const ReaderException('The hub\'s answer didn\'t make sense to Den.');
    return Map<String, Object?>.from(wire);
  }
}
