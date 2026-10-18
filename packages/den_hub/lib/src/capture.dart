import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:shelf/shelf.dart';

import 'context.dart';
import 'http_util.dart';
import 'setup.dart' show restrictToOwner;

/// Reading what the family shares, once for every device (`/api/v1/capture`). A parent picks
/// the hub's reader (Claude with a key, or a model at home); any approved device then asks the
/// hub to read a photo, an email or a sentence and gets back den_capture's JSON, which the
/// device resolves, checks and writes as its own acting member. Requests are signed with the
/// device's key ([DeviceRequest]); there are no tokens. The key lives in the hub's own data
/// directory, readable by its owner only, and never in the family's log or an answer.
class HubCapture {
  /// Creates the capture endpoints for [hub].
  HubCapture(this.hub);

  /// Shared hub context.
  final HubContext hub;

  /// Most reads running at once; more wait for a free one with `429`.
  static const int maxReading = 4;

  /// Largest request: a few photos or a PDF, base64.
  static const int maxBody = 30 * 1024 * 1024;

  static const String _doc = 'capture';

  final NonceBook _nonces = NonceBook();
  int _reading = 0;

  /// Adds the capture routes.
  void register(Routes routes) {
    routes
      ..add('GET', '/api/v1/capture/reader', (r, _) => status(r))
      ..add('PUT', '/api/v1/capture/reader', (r, _) => configure(r))
      ..add('POST', '/api/v1/capture/read', (r, _) => read(r));
  }

  Map<String, Object?> get _saved => hub.state.read(_doc);

  HubReaderKind get _kind => HubReaderKind.values.asNameMap()[_saved['kind']] ?? HubReaderKind.none;

  /// The reader the family set up, or null.
  CaptureReader? reader() {
    final s = _saved;
    switch (_kind) {
      case HubReaderKind.claude:
        final key = s['key'];
        if (key is! String || key.isEmpty) return null;
        return ClaudeReader(apiKey: key, model: s['model'] as String? ?? ClaudeReader.defaultModel, client: hub.http);
      case HubReaderKind.home:
        final base = HomeModelReader.baseFor(s['address'] as String? ?? '');
        if (base == null) return null;
        return HomeModelReader(base: base, model: s['model'] as String? ?? HomeModelReader.defaultModel, client: hub.http);
      case HubReaderKind.none:
        return null;
    }
  }

  /// What devices see of the reader: never the key.
  HubReaderStatus describe() {
    final s = _saved;
    final r = reader();
    return HubReaderStatus(
      kind: r == null ? HubReaderKind.none : _kind,
      reader: r?.info,
      deviceFirst: s['device_first'] != false,
      model: s['model'] as String?,
      address: s['address'] as String?,
      keySaved: s['key'] is String && (s['key'] as String).isNotEmpty,
    );
  }

  /// Turns away a request from no device of this family before its body is read.
  void _precheck(Request request) {
    if (!hub.ready) throw ApiError.notReady();
    final id = request.headers[DeviceRequest.device];
    final d = id == null ? null : hub.den.device(id);
    if (d == null || !d.approved || d.revoked) {
      throw ApiError.unauthorized('This needs a request signed by a device in this family.');
    }
  }

  Future<DeviceRequestCheck> _check(Request request, List<int> body) async {
    if (!hub.ready) throw ApiError.notReady();
    final c = await DeviceRequest.verify(
      hub.den,
      method: request.method,
      url: request.requestedUri,
      headers: request.headers,
      body: body,
      seen: _nonces,
    );
    if (!c.ok) {
      hub.log.warn('Refused a capture request: ${c.problem}');
      throw ApiError.unauthorized('This needs a request signed by a device in this family.');
    }
    return c;
  }

  /// `GET /api/v1/capture/reader`: the hub's reader, for any device in the family.
  Future<Response> status(Request request) async {
    await _check(request, const []);
    return jsonResponse(describe().toJson());
  }

  /// `PUT /api/v1/capture/reader`: a parent's phone (or the hub's own owner) sets the reader.
  Future<Response> configure(Request request) async {
    _precheck(request);
    final bytes = await readBodyBytes(request, limit: 64 * 1024);
    final c = await _check(request, bytes);
    final parent = c.actor?.isParent ?? false;
    if (!parent || c.device!.mode == DeviceMode.shared) {
      throw ApiError.denied('Only a parent\'s phone can choose what the hub reads with.');
    }
    final json = _json(bytes);
    final kind = HubReaderKind.values.asNameMap()[json['kind']];
    if (kind == null) throw ApiError.invalid('"kind" must be none, claude or home.', field: 'kind');
    final deviceFirst = json['device_first'] is bool ? json['device_first']! as bool : true;
    final before = _saved;
    final Map<String, Object?> next;
    switch (kind) {
      case HubReaderKind.none:
        next = {'kind': 'none', 'device_first': deviceFirst};
      case HubReaderKind.claude:
        final key = json['key'];
        final kept = before['key'];
        if (key != null && (key is! String || !key.trim().startsWith('sk-ant-') || key.length > 300)) {
          throw ApiError.invalid('That doesn\'t look like a Claude API key. Keys start with sk-ant-.', field: 'key');
        }
        final use = key is String ? key.trim() : (kept is String && kept.isNotEmpty ? kept : null);
        if (use == null) throw ApiError.invalid('Claude needs an API key.', field: 'key');
        final model = json['model'] as String? ?? ClaudeReader.defaultModel;
        if (!ClaudeReader.models.containsKey(model)) throw ApiError.invalid('Den doesn\'t offer that model.', field: 'model');
        next = {'kind': 'claude', 'key': use, 'model': model, 'device_first': deviceFirst};
      case HubReaderKind.home:
        final address = json['address'];
        if (address is! String || HomeModelReader.baseFor(address) == null) {
          throw ApiError.invalid('"address" must be the home model\'s address, like 192.168.1.20:11434.', field: 'address');
        }
        final model = json['model'];
        if (model != null && (model is! String || model.trim().isEmpty || model.length > 100)) {
          throw ApiError.invalid('"model" must be the model\'s name.', field: 'model');
        }
        next = {
          'kind': 'home',
          'address': address.trim(),
          'model': (model as String?)?.trim() ?? HomeModelReader.defaultModel,
          'device_first': deviceFirst,
        };
    }
    await hub.state.save(_doc, next);
    final dir = hub.config.dataDir;
    if (dir != null) restrictToOwner('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}$_doc.json');
    hub.log.info('${c.actor!.name} set what the hub reads with: ${kind.name}');
    return jsonResponse(describe().toJson());
  }

  /// `POST /api/v1/capture/read`: reads what a device shared with the family's reader.
  Future<Response> read(Request request) async {
    _precheck(request);
    final bytes = await readBodyBytes(request, limit: maxBody);
    final c = await _check(request, bytes);
    final actor = c.actor;
    if (actor == null) throw ApiError.denied('Sign in on this screen to add things.');
    final allowed = const [DenAction.editEvents, DenAction.editChores, DenAction.editLists].any((a) => can(actor, a));
    if (!allowed) throw ApiError.denied('${actor.name} can\'t add anything Den reads.');
    final reader = this.reader();
    if (reader == null) {
      throw ApiError(409, 'no_reader',
          'The hub has nothing to read with yet. A parent can set it up under Settings, AI and automations.');
    }
    CaptureInput input;
    try {
      input = CaptureInput.fromJson(_json(bytes));
    } on FormatException {
      throw ApiError.invalid('That isn\'t something Den can read.');
    }
    final seen = [
      for (final f in input.files)
        if ((f.isImage && reader.info.reads(ReaderInput.image)) || (f.isPdf && reader.info.reads(ReaderInput.pdf))) f,
    ];
    input = CaptureInput(kind: input.kind, text: input.text, files: seen, link: input.link, subject: input.subject);
    if (input.isEmpty) {
      throw ApiError.invalid('The hub\'s reader reads text. Send the words this device found in the photo.');
    }
    if (_reading >= maxReading) {
      throw ApiError(429, 'busy', 'The hub is reading other things. Try again in a moment.', details: {'retry': true});
    }
    _reading++;
    try {
      // The family as the person sharing sees it: their lists, not a parent's private ones.
      final context = await hub.gate.run(actor.id, null, () => CaptureContext.of(hub.den));
      final wire = await reader.read(ReadRequest(input, context));
      return jsonResponse({'wire': wire, 'reader': reader.info.toJson()});
    } on ReaderException catch (e) {
      throw ApiError(502, 'reader_failed', e.message, details: {'retry': e.retry});
    } finally {
      _reading--;
    }
  }

  static Map<String, Object?> _json(List<int> bytes) {
    try {
      final v = jsonDecode(utf8.decode(bytes));
      if (v is Map) return Map<String, Object?>.from(v);
    } on FormatException {
      // Answered below.
    }
    throw ApiError.invalid('The body must be a JSON object.');
  }
}
