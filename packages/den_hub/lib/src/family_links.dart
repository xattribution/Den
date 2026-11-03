import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

import 'access.dart' show bearerToken;
import 'context.dart';
import 'device_auth.dart';
import 'hub.dart';
import 'http_util.dart';
import 'log.dart';
import 'setup.dart' show restrictToOwner;

/// Links between families (docs/hub-api.md, "Linked families").
///
/// A parent makes a link on their own phone ([offer]) and sends its address to a parent of the
/// other family, who accepts it on theirs ([accept]). The two hubs then know each other: each
/// keeps the other's secret, and the addresses the other answers at (its family address, and
/// the address its parent's phone reached it at, on the home network or a VPN).
///
/// From then on the hubs keep what each family shares with the other in step ([syncAll]): the
/// family's calendar (its Everyone events) and the lists a parent picked, each one either for
/// the other family to see, or to change as well. One request does both directions: a hub sends
/// what it shares and the copies it keeps of the other family's things, and gets the other's back
/// ([peerSync]), so a link works even when only one of the two hubs can reach the other.
///
/// What came from the other family is kept in this family's own log, written by the hub: their
/// lists and events carry the link (`link`), their items and occurrences belong to those. Each
/// field keeps the time it was last changed in the family that changed it, and the later change
/// wins on both sides. A thing shared only to see follows its family exactly.
class FamilyLinks implements HubService {
  /// Creates the endpoints and the sync for [hub], checking parents' signatures with [auth].
  FamilyLinks(this.hub, this.auth);

  /// Shared hub context.
  final HubContext hub;

  /// Device signatures.
  final DeviceAuth auth;

  /// How often linked hubs sync when nothing changed.
  static Duration interval = const Duration(seconds: 15);

  /// How long a hub waits for the other family's hub.
  static const Duration timeout = Duration(seconds: 15);

  /// Failed syncs in a row before the family hears that the other hub can't be reached.
  static const int quietFailures = 3;

  /// What an invite's address starts with, after the hub's address.
  static const String path = '/family-link/';

  static const String _doc = 'family_links';

  /// The fields that travel, by type: never ones naming the family's people or categories.
  static const Map<String, List<String>> _fields = {
    RecordType.list: ['title', 'icon', 'kind', 'lifecycle', 'needBy'],
    RecordType.event: ['title', 'notes', 'location', 'start', 'end', 'allDay', 'tz', 'rrule', 'countdown'],
    RecordType.item: ['list', 'text', 'qty', 'store', 'checked', 'order'],
    RecordType.eventException: ['event', 'occurrence', 'cancelled', 'patch'],
  };

  /// The occurrence changes that travel.
  static const Set<String> _patchKeys = {'title', 'notes', 'location', 'start', 'end', 'allDay'};

  /// Lists before their items, events before their occurrences.
  static const List<String> _order = [RecordType.list, RecordType.event, RecordType.item, RecordType.eventException];

  final Random _random = Random.secure();

  @override
  String get name => 'Linked families';

  Timer? _timer;
  Timer? _soon;
  StreamSubscription<Set<String>>? _changes;
  Future<void> _running = Future.value();
  bool _stopping = false;

  /// Adds the routes.
  void register(Routes routes) {
    routes
      ..add('POST', '/api/v1/families/<id>/offer', (r, p) => offer(r, p['id']!))
      ..add('POST', '/api/v1/families/accept', (r, _) => accept(r))
      ..add('POST', '/api/v1/families/peer/<id>/accept', (r, p) => peerAccept(r, p['id']!))
      ..add('POST', '/api/v1/families/peer/<id>/sync', (r, p) => peerSync(r, p['id']!))
      ..add('POST', '/api/v1/families/peer/<id>/end', (r, p) => peerEnd(r, p['id']!));
  }

  Map<String, Object?> get _links => hub.state.read(_doc);

  Map<String, Object?>? _entry(String id) {
    final raw = _links[id];
    return raw is Map<String, Object?> ? raw : null;
  }

  Future<void> _save() async {
    await hub.state.save(_doc);
    final dir = hub.config.dataDir;
    if (dir != null) restrictToOwner('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}$_doc.json', warn: hub.log.warn);
  }

  @override
  Future<void> start() async {
    _stopping = false;
    _timer = Timer.periodic(interval, (_) => unawaited(syncAll()));
    _changes = hub.den.onChange.listen((types) {
      if (!types.any(const {
        RecordType.familyLink, RecordType.list, RecordType.item, RecordType.event, RecordType.eventException,
      }.contains)) {
        return;
      }
      _soon?.cancel();
      _soon = Timer(const Duration(seconds: 1), () => unawaited(syncAll()));
    });
    unawaited(syncAll());
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    _timer?.cancel();
    _soon?.cancel();
    await _changes?.cancel();
    await _running.timeout(timeout, onTimeout: () {});
    await _save();
  }

  /// Runs [body] after whatever sync is running: one at a time, the other family's requests
  /// included.
  Future<T> _queue<T>(Future<T> Function() body) {
    final run = _running.then((_) => body());
    _running = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  String _secret() => base64Url.encode(List.generate(32, (_) => _random.nextInt(256))).replaceAll('=', '');

  /// The addresses this hub answers at: the family's address, and [request]'s.
  List<String> _addresses(Request request) {
    final direct = requestBase(request, null, trusted: hub.config.trustedProxies).toString();
    final public = hub.config.publicUrl?.replace(path: '', query: null, fragment: null).toString();
    return [?public, direct].map(_trim).toSet().toList();
  }

  static String _trim(String url) => url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  // ------------------------------------------------------------------------- a parent's phone

  /// `POST /api/v1/families/{id}/offer`, signed by a parent's own device, for a link they made
  /// (`familyLink` {id}, waiting): answers the address to send the other family's parent, as
  /// `url`. Asked again before they accept, it answers the same address.
  Future<Response> offer(Request request, String id) async {
    final check = await auth.parent(request, message: 'Only a parent\'s own phone can link with another family.');
    final link = await hub.gate.asHub(() => hub.den.familyLink(id));
    if (link == null) throw ApiError.notFound(type: 'familyLink', message: 'There\'s no family link with that id.');
    if (link.status != LinkStatus.waiting) {
      throw ApiError(409, 'linked', 'That family link was accepted already. Make a new one for another family.');
    }
    final entry = _entry(id);
    final String secret;
    if (entry != null && entry['role'] == 'offer' && entry['peer'] == null && entry['secret'] is String) {
      secret = entry['secret']! as String;
      entry['mine'] = _addresses(request);
    } else {
      secret = _secret();
      _links[id] = {'role': 'offer', 'secret': secret, 'mine': _addresses(request), 'made': hub.now()};
    }
    await _save();
    hub.log.info('${check.actor!.name} made a link for another family');
    final mine = (_entry(id)!['mine']! as List).cast<String>();
    return jsonResponse({'id': id, 'url': '${mine.first}$path$id/$secret'});
  }

  /// `POST /api/v1/families/accept` `{"url": "<a link the other family's parent sent>"}`, signed by
  /// a parent's own device, after they added the link (`familyLink` with the link's id): this
  /// hub tells the other family's hub, and the families are linked. Answers the other family's
  /// `name`.
  Future<Response> accept(Request request) async {
    final signed = await auth.withBody(request, limit: 4096);
    final check = DeviceAuth.parentOf(signed.check, message: 'Only a parent\'s own phone can link with another family.');
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(signed.body));
    } on FormatException {
      throw ApiError.invalid('The body must be a JSON object.');
    }
    final parsed = json is Map ? parseLinkUrl(json['url']) : null;
    if (parsed == null) {
      throw ApiError.invalid('That isn\'t a family link. Ask the other family\'s parent to send it again.', field: 'url');
    }
    final link = await hub.gate.asHub(() => hub.den.familyLink(parsed.id));
    if (link == null) throw ApiError.notFound(type: 'familyLink', message: 'Add the family link in the app first.');
    if (link.status == LinkStatus.linked) return jsonResponse({'id': parsed.id, 'name': link.name});
    final family = hub.den.familyId!;
    final mine = _addresses(request);
    final http.Response answer;
    try {
      answer = await hub.http
          .post(
            Uri.parse('${parsed.base}/api/v1/families/peer/${parsed.id}/accept'),
            headers: {'authorization': 'Bearer ${parsed.secret}', 'content-type': 'application/json'},
            body: jsonEncode({'family': family, 'name': hub.den.family?.name ?? '', 'addresses': mine}),
          )
          .timeout(timeout);
    } on Object {
      throw ApiError(502, 'unreachable',
          'Den couldn\'t reach the other family\'s hub at ${parsed.base}. Check that this hub can reach it, then try again.');
    }
    final body = _decode(answer.body);
    if (answer.statusCode != 200 || body == null || body['family'] is! String) {
      final message = body?['error'] is Map ? (body!['error']! as Map)['message'] : null;
      throw ApiError(409, 'refused', message is String ? message : 'The other family\'s hub didn\'t take that link.');
    }
    final peer = body['family']! as String;
    if (peer == family) throw ApiError(409, 'own', 'That link is this family\'s own.');
    _links[parsed.id] = {
      'role': 'accept',
      'secret': parsed.secret,
      'peer': peer,
      'mine': mine,
      'addresses': {parsed.base, ..._strings(body['addresses'])}.toList(),
      'made': hub.now(),
    };
    await _save();
    final name = _name(body['name']);
    await hub.gate.asHub(() => hub.den.noteFamilyLink(parsed.id, {'status': LinkStatus.linked.name, 'name': name, 'peer': peer}));
    hub.log.info('${check.actor!.name} linked the family with ${familyName(name)}');
    _soon?.cancel();
    _soon = Timer(Duration.zero, () => unawaited(syncAll()));
    return jsonResponse({'id': parsed.id, 'name': name});
  }

  /// The parts of a family link's address: `<hub address>/family-link/<id>/<secret>`.
  static ({String base, String id, String secret})? parseLinkUrl(Object? url) {
    if (url is! String) return null;
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) return null;
    final s = uri.pathSegments;
    final at = s.indexOf('family-link');
    if (at < 0 || s.length != at + 3) return null;
    final id = s[at + 1], secret = s[at + 2];
    if (!RegExp(r'^[A-Za-z0-9_\-]{8,80}$').hasMatch(id) || !RegExp(r'^[A-Za-z0-9_\-]{20,100}$').hasMatch(secret)) return null;
    final prefix = s.sublist(0, at).join('/');
    final base = Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null).toString();
    return (base: _trim(prefix.isEmpty ? base : '$base/$prefix'), id: id, secret: secret);
  }

  // ------------------------------------------------------------------------ the other family's hub

  /// The link [id]'s entry when [request] carries its secret; throws a `404` otherwise, the same
  /// for every wrong guess.
  Map<String, Object?> _peerEntry(Request request, String id) {
    hub.checkFailures(request);
    final entry = _entry(id);
    final given = bearerToken(request.headers['authorization']);
    final secret = entry?['secret'];
    if (entry == null || given == null || secret is! String || !_same(given, secret)) {
      hub.failed(request);
      throw ApiError.notFound(type: 'familyLink', message: 'There\'s no family link there.');
    }
    return entry;
  }

  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<Map<String, Object?>> _body(Request request) async {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(await readBodyBytes(request, limit: 8 * 1024 * 1024)));
    } on FormatException {
      throw ApiError.invalid('The body must be a JSON object.');
    }
    if (json is! Map<String, Object?>) throw ApiError.invalid('The body must be a JSON object.');
    return json;
  }

  /// `POST /api/v1/families/peer/{id}/accept` `{"family", "name", "addresses"}`, from the other
  /// family's hub with the link's secret: they accepted. Once only, for one family.
  Future<Response> peerAccept(Request request, String id) async {
    final entry = _peerEntry(request, id);
    final body = await _body(request);
    final family = body['family'];
    if (family is! String || !RegExp(r'^[a-z2-7]{8,40}$').hasMatch(family)) throw ApiError.invalid('"family" is missing.');
    if (family == hub.den.familyId) throw ApiError(409, 'own', 'That link is your own family\'s.');
    if (entry['role'] != 'offer') throw ApiError.notFound(type: 'familyLink', message: 'There\'s no family link there.');
    final already = entry['peer'];
    if (already != null && already != family) {
      throw ApiError(409, 'taken', 'Another family accepted that link already. Ask for a new one.');
    }
    final link = await hub.gate.asHub(() => hub.den.familyLink(id));
    if (link == null || link.status == LinkStatus.ended) {
      throw ApiError(410, 'ended', 'That family link was ended. Ask for a new one.');
    }
    final name = _name(body['name']);
    entry
      ..['peer'] = family
      ..['addresses'] = _strings(body['addresses']).take(4).toList();
    await _save();
    if (link.status == LinkStatus.waiting || link.name != name || link.peer != family) {
      await hub.gate.asHub(() => hub.den.noteFamilyLink(id, {'status': LinkStatus.linked.name, 'name': name, 'peer': family}));
    }
    hub.log.info('${familyName(name)} accepted a family link');
    return jsonResponse({
      'family': hub.den.familyId,
      'name': hub.den.family?.name ?? '',
      'addresses': _strings(entry['mine']),
    });
  }

  /// `POST /api/v1/families/peer/{id}/sync` with what the other family shares and the copies it
  /// keeps of this family's ([state]): this hub takes in what changed, and answers the same from
  /// its side.
  Future<Response> peerSync(Request request, String id) async {
    final entry = _peerEntry(request, id);
    final body = await _body(request);
    if (entry['peer'] == null || body['family'] != entry['peer']) {
      throw ApiError(409, 'not_linked', 'That family link isn\'t accepted yet.');
    }
    // Not behind this hub's own sync, which may be waiting on the other hub right now.
    final link = await hub.gate.asHub(() => hub.den.familyLink(id));
    if (link == null || link.status == LinkStatus.ended) {
      throw ApiError(410, 'ended', 'That family link was ended.');
    }
    if (link.status == LinkStatus.waiting) {
      await hub.gate.asHub(() => hub.den.noteFamilyLink(id, {'status': LinkStatus.linked.name}));
    }
    await _merge(id, entry, body);
    await _save();
    return jsonResponse(await hub.gate.asHub(() => state(hub.den.familyLink(id)!, entry)));
  }

  /// `POST /api/v1/families/peer/{id}/end`, from the other family's hub: they ended the link.
  Future<Response> peerEnd(Request request, String id) async {
    final entry = _peerEntry(request, id);
    entry['ended'] = true;
    await _save();
    final link = await hub.gate.asHub(() => hub.den.familyLink(id));
    if (link != null && link.status != LinkStatus.ended) {
      await hub.gate.asHub(() => hub.den.noteFamilyLink(id, {'status': LinkStatus.ended.name}));
    }
    await _removeCopies(id);
    return jsonResponse({'ok': true});
  }

  // ------------------------------------------------------------------------------------- sync

  /// Syncs every accepted link with the other family's hub, and tells the other hub about links
  /// a parent here ended. Does nothing while the hub catches up after a restore.
  Future<void> syncAll() => _queue(() async {
        if (_stopping || hub.catchingUp || !hub.ready) return;
        final links = await hub.gate.asHub(() => hub.den.familyLinks);
        for (final link in links) {
          if (_stopping) return;
          final entry = _entry(link.id);
          if (entry == null || entry['peer'] == null) continue;
          try {
            if (link.status == LinkStatus.ended) {
              if (entry['ended'] != true) await _end(link.id, entry);
            } else {
              await _syncOne(link.id, entry);
            }
          } on Object catch (e, st) {
            hub.log.error('Syncing a linked family failed: ${describeError(e, st)}');
          }
        }
        await _save();
      });

  Future<void> _end(String id, Map<String, Object?> entry) async {
    entry['ended'] = true;
    for (final address in _strings(entry['addresses'])) {
      try {
        final r = await hub.http
            .post(Uri.parse('$address/api/v1/families/peer/$id/end'), headers: {'authorization': 'Bearer ${entry['secret']}'})
            .timeout(timeout);
        if (r.statusCode == 200) break;
      } on Object {
        // The other hub hears of it when it next syncs (410).
      }
    }
    await _removeCopies(id);
  }

  Future<void> _syncOne(String id, Map<String, Object?> entry) async {
    final link = await hub.gate.asHub(() => hub.den.familyLink(id));
    if (link == null) return;
    final mine = jsonEncode(await hub.gate.asHub(() => state(link, entry)));
    final addresses = _strings(entry['addresses']);
    final good = entry['good'];
    if (good is String && addresses.remove(good)) addresses.insert(0, good);
    for (final address in addresses) {
      final http.Response answer;
      try {
        answer = await hub.http
            .post(
              Uri.parse('$address/api/v1/families/peer/$id/sync'),
              headers: {'authorization': 'Bearer ${entry['secret']}', 'content-type': 'application/json'},
              body: mine,
            )
            .timeout(timeout);
      } on Object {
        continue;
      }
      if (answer.statusCode == 410) {
        entry['ended'] = true;
        await hub.gate.asHub(() => hub.den.noteFamilyLink(id, {'status': LinkStatus.ended.name}));
        await _removeCopies(id);
        return;
      }
      final body = _decode(answer.body);
      if (answer.statusCode != 200 || body == null || body['family'] != entry['peer']) continue;
      entry
        ..['good'] = address
        ..['failures'] = 0;
      await _merge(id, entry, body);
      if (link.problem != null) await hub.gate.asHub(() => hub.den.noteFamilyLink(id, {'problem': null}));
      return;
    }
    final failures = ((entry['failures'] as num?)?.toInt() ?? 0) + 1;
    entry['failures'] = failures;
    // Quiet when the other hub answers this one's requests itself (it can reach this one).
    final heard = (entry['heard'] as num?)?.toInt() ?? 0;
    if (failures >= quietFailures && hub.now() - heard > interval.inMilliseconds * 4 && link.problem == null) {
      await hub.gate.asHub(
          () => hub.den.noteFamilyLink(id, {'problem': 'Den can\'t reach ${familyName(link.name)}\'s hub right now.'}));
    }
  }

  /// What this hub sends for link [link]: this family's id and name, what it shares and how
  /// much, and the records: what it shares, and the copies it keeps of the other family's
  /// things (its own changes to them travel back that way). Each record carries its owner and,
  /// for each field, when the family that changed it last did.
  Map<String, Object?> state(FamilyLink link, Map<String, Object?> entry) {
    final den = hub.den;
    final me = den.familyId!;
    final peer = entry['peer'] as String?;
    final at = _at(entry);
    final records = <Map<String, Object?>>[];
    if (link.status == LinkStatus.linked) {
      final owned = _owned(link);
      for (final rec in owned) {
        records.add(_export(rec, me, at));
      }
      if (peer != null) {
        for (final rec in _copies(link.id)) {
          records.add(_export(rec, peer, at));
        }
      }
    }
    return {
      'family': me,
      'name': den.family?.name ?? '',
      'shares': {for (final e in link.share.entries) e.key: e.value.name},
      'records': records,
    };
  }

  /// This family's records [link] shares, live ones only (one gone tells by not coming).
  List<Rec> _owned(FamilyLink link) {
    final den = hub.den;
    final out = <Rec>[];
    final share = link.share;
    if (share.containsKey(Shared.calendar)) {
      final events = <String>{};
      for (final rec in den.recordsOf(RecordType.event)) {
        if (rec.deleted || rec.space != Space.family || rec.fields['link'] != null) continue;
        events.add(rec.id);
        out.add(rec);
      }
      for (final rec in den.recordsOf(RecordType.eventException)) {
        if (rec.deleted || rec.space != Space.family || !events.contains(rec.fields['event'])) continue;
        out.add(rec);
      }
    }
    final lists = <String, String>{};
    for (final rec in den.recordsOf(RecordType.list)) {
      if (rec.deleted || rec.fields['link'] != null || !share.containsKey(rec.id)) continue;
      lists[rec.id] = rec.space;
      out.add(rec);
    }
    for (final rec in den.recordsOf(RecordType.item)) {
      if (rec.deleted || lists[rec.fields['list']] != rec.space) continue;
      out.add(rec);
    }
    return out;
  }

  /// The copies this family keeps of the other family's things through link [id]: their lists
  /// and events, and the items and occurrences in them; removed ones too, so a removal here
  /// travels.
  List<Rec> _copies(String id) {
    final den = hub.den;
    final out = <Rec>[];
    final lists = <String>{}, events = <String>{};
    for (final rec in den.recordsOf(RecordType.list)) {
      if (rec.space == Space.family && rec.fields['link'] == id) {
        lists.add(rec.id);
        out.add(rec);
      }
    }
    for (final rec in den.recordsOf(RecordType.event)) {
      if (rec.space == Space.family && rec.fields['link'] == id) {
        events.add(rec.id);
        out.add(rec);
      }
    }
    for (final rec in den.recordsOf(RecordType.item)) {
      if (rec.space == Space.family && lists.contains(rec.fields['list'])) out.add(rec);
    }
    for (final rec in den.recordsOf(RecordType.eventException)) {
      if (rec.space == Space.family && events.contains(rec.fields['event'])) out.add(rec);
    }
    return out;
  }

  Map<String, Object?> _at(Map<String, Object?> entry) {
    final raw = entry['at'];
    if (raw is Map<String, Object?>) return raw;
    final fresh = <String, Object?>{};
    entry['at'] = fresh;
    return fresh;
  }

  /// When field [field] of [rec] last changed in the family that changed it: the time this hub
  /// kept for a value it wrote from the other family, else the change's own.
  static String? _when(Rec rec, String field, Map<String, Object?> at) {
    Hlc? time;
    if (field == 'patch') {
      for (final e in rec.fieldTimes.entries) {
        if (e.key == 'patch' || e.key.startsWith('patch.')) time = time == null || e.value.compareTo(time) > 0 ? e.value : time;
      }
    } else {
      time = rec.fieldTimes[field];
    }
    if (time == null) return null;
    final kept = at['${rec.type}/${rec.id}/$field'];
    if (kept is List && kept.length == 2 && kept[0] == time.toString()) return kept[1] as String;
    return time.toString();
  }

  static Object? _value(Rec rec, String field) {
    final v = rec.fields[field];
    if (field == 'patch' && v is Map) {
      return {
        for (final e in v.entries)
          if (_patchKeys.contains(e.key) && e.value != null) e.key: e.value,
      };
    }
    return v;
  }

  Map<String, Object?> _export(Rec rec, String owner, Map<String, Object?> at) {
    final fields = <String, Object?>{};
    final times = <String, Object?>{};
    for (final f in [..._fields[rec.type]!, '_deleted']) {
      if (!rec.fields.containsKey(f)) continue;
      fields[f] = _value(rec, f);
      times[f] = _when(rec, f, at) ?? rec.created.toString();
    }
    return {'type': rec.type, 'id': rec.id, 'owner': owner, 'fields': fields, 'at': times};
  }

  /// Takes in what the other family's hub sent for link [id] ([state] from its side).
  Future<void> _merge(String id, Map<String, Object?> entry, Map<String, Object?> body) async {
    entry['heard'] = hub.now();
    final peer = entry['peer'] as String?;
    if (peer == null || body['family'] != peer) return;
    final theirs = <String, ShareLevel>{
      for (final e in ((body['shares'] as Map?) ?? const {}).entries)
        if (e.key is String) e.key as String: ?ShareLevel.values.firstWhereOrNull((l) => l.name == e.value),
    };
    final records = [
      for (final r in (body['records'] as List?) ?? const <Object?>[])
        if (r is Map<String, Object?> && _fields.containsKey(r['type']) && r['id'] is String && r['fields'] is Map) r,
    ]..sort((a, b) => _order.indexOf(a['type']! as String).compareTo(_order.indexOf(b['type']! as String)));
    final at = _at(entry);
    final seenBefore = {for (final v in (entry['seen'] as List?) ?? const <Object?>[]) if (v is String) v};
    final seenNow = <String>{};
    await hub.gate.asHub(() async {
      final link = hub.den.familyLink(id);
      if (link == null || link.status != LinkStatus.linked) return;
      final name = _name(body['name']);
      final had = {for (final e in link.theirs.entries) e.key: e.value.name};
      final now = {for (final e in theirs.entries) e.key: e.value.name};
      if (!const DeepCollectionEquality().equals(had, now) || (name.isNotEmpty && name != link.name)) {
        await hub.den.noteFamilyLink(id, {'theirs': now, if (name.isNotEmpty) 'name': name});
      }
      final me = hub.den.familyId!;
      for (final r in records) {
        try {
          if (r['owner'] == me) {
            await _takeOwn(link, r, at);
          } else if (r['owner'] == peer) {
            final key = await _takeTheirs(link, theirs, r, at);
            if (key != null) seenNow.add(key);
          }
        } on Object catch (e) {
          hub.log.warn('A linked family\'s ${r['type']} wasn\'t taken in: $e');
        }
      }
      // What they stopped sharing, or removed, goes from here too.
      for (final rec in _copies(id)) {
        final key = '${rec.type}/${rec.id}';
        if (rec.deleted || seenNow.contains(key) || !seenBefore.contains(key)) continue;
        try {
          await _write(rec.type, rec.id, rec.space, {'_deleted': true}, null, at);
        } on Object catch (e) {
          hub.log.warn('A linked family\'s ${rec.type} wasn\'t removed: $e');
        }
      }
    });
    entry['seen'] = seenNow.toList()..sort();
    _prune(at);
  }

  /// One of this family's own records, as the other family has it: their changes count when this
  /// family lets them change it, and only where they are newer.
  Future<void> _takeOwn(FamilyLink link, Map<String, Object?> r, Map<String, Object?> at) async {
    final den = hub.den;
    final type = r['type']! as String, id = r['id']! as String;
    final fields = Map<String, Object?>.from(r['fields']! as Map);
    final times = Map<String, Object?>.from((r['at'] as Map?) ?? const {});
    Rec? local;
    String? space;
    ShareLevel? level;
    switch (type) {
      case RecordType.event:
        local = den.recordAt(Space.family, type, id);
        space = Space.family;
        level = link.share[Shared.calendar];
      case RecordType.eventException:
        local = den.recordAt(Space.family, type, id);
        final event = den.recordAt(Space.family, RecordType.event, (local?.fields['event'] ?? fields['event']) as String? ?? '');
        if (event == null || event.deleted || event.fields['link'] != null) return;
        space = Space.family;
        level = link.share[Shared.calendar];
      case RecordType.list:
        local = den.recordsOf(type).firstWhereOrNull((rec) => rec.id == id && rec.fields['link'] == null);
        if (local == null) return;
        space = local.space;
        level = link.share[id];
      case RecordType.item:
        local = den.recordsOf(type).firstWhereOrNull((rec) => rec.id == id);
        final listId = (local?.fields['list'] ?? fields['list']) as String?;
        final list = den.recordsOf(RecordType.list).firstWhereOrNull((rec) => rec.id == listId && rec.fields['link'] == null);
        if (list == null || list.deleted) return;
        space = list.space;
        level = link.share[list.id];
    }
    if (level != ShareLevel.edit || space == null) return;
    if (local != null && (local.space != space || local.fields['link'] != null)) return;
    await _apply(type, id, space, local, fields, times, at, owner: false);
  }

  /// One of the other family's records: kept here as a copy, through [link], while they share
  /// it. Returns the key it is seen by, or null when they don't share it.
  Future<String?> _takeTheirs(
      FamilyLink link, Map<String, ShareLevel> theirs, Map<String, Object?> r, Map<String, Object?> at) async {
    final den = hub.den;
    final type = r['type']! as String, id = r['id']! as String;
    final fields = Map<String, Object?>.from(r['fields']! as Map);
    final times = Map<String, Object?>.from((r['at'] as Map?) ?? const {});
    final local = den.recordAt(Space.family, type, id);
    ShareLevel? level;
    switch (type) {
      case RecordType.event:
        if (local != null && local.fields['link'] != link.id) return null;
        level = theirs[Shared.calendar];
      case RecordType.eventException:
        final event = den.recordAt(Space.family, RecordType.event, (local?.fields['event'] ?? fields['event']) as String? ?? '');
        if (event == null || event.fields['link'] != link.id) return null;
        level = theirs[Shared.calendar];
      case RecordType.list:
        if (local != null && local.fields['link'] != link.id) return null;
        level = theirs[id];
      case RecordType.item:
        final listId = (local?.fields['list'] ?? fields['list']) as String? ?? '';
        final list = den.recordAt(Space.family, RecordType.list, listId);
        if (list == null || list.fields['link'] != link.id) return null;
        level = theirs[listId];
    }
    if (level == null) return null;
    if (local == null && fields['_deleted'] == true) return '$type/$id';
    if (local == null && (type == RecordType.list || type == RecordType.event)) fields['link'] = link.id;
    await _apply(type, id, Space.family, local, fields, times, at, owner: level == ShareLevel.see);
    return '$type/$id';
  }

  /// Writes what of [fields] should change [local] (record [id] of [type] in [space]): with
  /// [owner], whatever differs (the other family's own, which this one only sees); otherwise
  /// each field whose time is later than the one it has here.
  Future<void> _apply(String type, String id, String space, Rec? local, Map<String, Object?> fields,
      Map<String, Object?> times, Map<String, Object?> at,
      {required bool owner}) async {
    final want = <String, Object?>{};
    final origin = <String, String>{};
    for (final e in fields.entries) {
      final f = e.key;
      if (f != '_deleted' && f != 'link' && !_fields[type]!.contains(f)) continue;
      final time = times[f] is String ? times[f]! as String : '';
      if (local != null) {
        if (f == 'link') continue;
        final have = _value(local, f);
        if (const DeepCollectionEquality().equals(have, e.value)) continue;
        if (!owner) {
          final mine = _when(local, f, at);
          if (mine != null && time.compareTo(mine) <= 0) continue;
        }
      }
      if (f == 'patch' && local != null && e.value is Map) {
        // Entry by entry, so what doesn't travel (who drives) stays as it is here.
        final have = (_value(local, f) as Map?) ?? const {};
        final next = e.value! as Map;
        for (final k in _patchKeys) {
          if (have[k] != next[k]) want['patch.$k'] = next[k];
        }
        if (time.isNotEmpty) origin['patch'] = time;
        continue;
      }
      want[f] = e.value;
      if (time.isNotEmpty) origin[f] = time;
    }
    if (want.isEmpty) return;
    final deleting = want['_deleted'];
    if (deleting == true) {
      await _write(type, id, space, {'_deleted': true}, origin, at);
      return;
    }
    if (local == null) want.remove('_deleted');
    if (want.isEmpty) return;
    await _write(type, id, space, want, origin, at);
  }

  Future<void> _write(String type, String id, String space, Map<String, Object?> fields, Map<String, String>? origin,
      Map<String, Object?> at) async {
    final made = await hub.den.writeLinked(type, id, space, fields);
    if (origin == null) return;
    for (final f in {for (final k in fields.keys) k.startsWith('patch.') ? 'patch' : k}) {
      final time = origin[f];
      if (time != null) at['$type/$id/$f'] = [made.hlc.toString(), time];
    }
  }

  /// Forgets kept times of values written over since.
  void _prune(Map<String, Object?> at) {
    if (at.length < 2000) return;
    final den = hub.den;
    at.removeWhere((key, value) {
      final parts = key.split('/');
      if (parts.length != 3 || value is! List) return true;
      final rec = den.recordsOf(parts[0]).firstWhereOrNull((r) => r.id == parts[1]);
      return rec == null || rec.fieldTimes[parts[2]]?.toString() != value[0];
    });
  }

  /// Removes every copy of the other family's things kept through link [id].
  Future<void> _removeCopies(String id) => hub.gate.asHub(() async {
        final at = _entry(id) == null ? <String, Object?>{} : _at(_entry(id)!);
        final copies = _copies(id).where((r) => !r.deleted).toList()
          ..sort((a, b) => _order.indexOf(b.type).compareTo(_order.indexOf(a.type)));
        for (final rec in copies) {
          try {
            await _write(rec.type, rec.id, rec.space, {'_deleted': true}, null, at);
          } on Object catch (e) {
            hub.log.warn('A linked family\'s ${rec.type} wasn\'t removed: $e');
          }
        }
      });

  static Map<String, Object?>? _decode(String text) {
    try {
      final json = jsonDecode(text);
      return json is Map<String, Object?> ? json : null;
    } on FormatException {
      return null;
    }
  }

  static List<String> _strings(Object? raw) => [
        for (final v in (raw as List?) ?? const <Object?>[])
          if (v is String && v.length <= 300 && (v.startsWith('http://') || v.startsWith('https://'))) _trim(v),
      ];

  static String _name(Object? raw) {
    if (raw is! String) return '';
    final t = raw.trim();
    return t.length > 100 ? t.substring(0, 100) : t;
  }

  /// "the Smith family", for a family named [name].
  static String familyName(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'the other family';
    final lower = n.toLowerCase();
    if (lower.startsWith('the ')) return 'the ${n.substring(4)}';
    if (lower.endsWith(' family')) return 'the $n';
    return 'the $n family';
  }
}
