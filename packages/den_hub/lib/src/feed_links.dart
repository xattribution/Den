import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import 'context.dart';
import 'device_auth.dart';
import 'http_util.dart';
import 'setup.dart' show restrictToOwner;

/// One calendar link: a secret address that opens one of the family's calendar feeds and
/// nothing else, read with the permissions of the parent who made it; a [shared] one, for
/// another family, holds the family's Everyone events and nothing more.
class FeedLink {
  /// Creates a link record.
  const FeedLink({
    required this.id,
    required this.hash,
    required this.member,
    required this.feed,
    required this.label,
    required this.made,
    this.device,
  });

  /// Reads a stored link; null when it isn't one.
  static FeedLink? fromJson(String id, Object? json) {
    if (json is! Map) return null;
    final hash = json['hash'], member = json['member'], feed = json['feed'], label = json['label'], made = json['made'];
    if (hash is! String || member is! String || feed is! String || label is! String || made is! int) return null;
    final device = json['device'];
    return FeedLink(
        id: id, hash: hash, member: member, feed: feed, label: label, made: made, device: device is String ? device : null);
  }

  /// The link's id, which never reveals its secret.
  final String id;

  /// SHA-256 of the secret in its address; the secret itself is never kept.
  final String hash;

  /// The parent who made it: the feed holds what they may read (a [shared] one, only what
  /// everyone in the family may).
  final String member;

  /// `family`, `shared` (for another family), or the member whose events it holds.
  final String feed;

  /// The feed kind for another family: the family's Everyone events only.
  static const String sharedFeed = 'shared';

  /// Whether this link is for another family ([sharedFeed]).
  bool get shared => feed == sharedFeed;

  /// What it's for: "Alex's iPhone".
  final String label;

  /// When it was made (UTC ms).
  final int made;

  /// The device it was made on; removing that device ends the link. Null for links made
  /// before the hub kept it, which end only with their maker.
  final String? device;

  /// The file its address ends with.
  String get file => '$feed.ics';

  /// As stored.
  Map<String, Object?> toJson() =>
      {'hash': hash, 'member': member, 'feed': feed, 'label': label, 'made': made, 'device': ?device};
}

/// Calendar links (`/api/v1/feeds`): "Show Den in iPhone Calendar". A parent's own device makes
/// a read-only address for the family's calendar or one person's; a phone's calendar app
/// subscribes to it (`webcal://`). Unlike an API token, the address opens only that one feed,
/// `GET /ics/<secret>/<family|memberId>.ics`, never the API; it reads with its maker's
/// permissions, so it holds exactly what the feed code gives that parent (their "Just me"
/// events included, a teen's private ones only while parents may see them). A link for another
/// family (`shared.ics`) reads as the family instead: Everyone events only, never Parents-only or
/// Just-me ones, and never events the family itself copied in from another family's share. Its
/// subscriber may also watch it (`/ics/<secret>/watch`) to hear of changes at once. Parents list
/// the family's links and turn any of them off; a link ends too when its maker leaves the family
/// or the device it was made on is removed. The hub keeps a hash of each secret, in its data
/// directory; the address is shown once.
class HubFeedLinks {
  /// Creates the endpoints for [hub], checking signatures with [auth].
  HubFeedLinks(this.hub, this.auth);

  /// Shared hub context.
  final HubContext hub;

  /// Device signatures.
  final DeviceAuth auth;

  /// Most links a family keeps at once.
  static const int maxLinks = 50;

  /// What every secret starts with, so a stray one is easy to recognize.
  static const String prefix = 'denfeed_';

  static const String _doc = 'feed_links';

  final Random _random = Random.secure();
  final StreamController<String> _turnedOff = StreamController.broadcast(sync: true);

  /// The ids of links as a parent turns them off.
  Stream<String> get turnedOff => _turnedOff.stream;

  /// Adds the routes.
  void register(Routes routes) {
    routes
      ..add('GET', '/api/v1/feeds', (r, _) => list(r))
      ..add('POST', '/api/v1/feeds', (r, _) => create(r))
      ..add('DELETE', '/api/v1/feeds/<id>', (r, p) => revoke(r, p['id']!));
  }

  Map<String, Object?> get _links => hub.state.read(_doc);

  Iterable<FeedLink> get _all => [for (final e in _links.entries) ?FeedLink.fromJson(e.key, e.value)];

  Future<void> _save() async {
    await hub.state.save(_doc);
    final dir = hub.config.dataDir;
    if (dir != null) restrictToOwner('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}$_doc.json', warn: hub.log.warn);
  }

  /// Whether [link] still works: its maker is in the family and the device it was made on
  /// hasn't been removed.
  bool _works(FeedLink link) {
    if (hub.den.member(link.member) == null) return false;
    final made = link.device;
    if (made == null) return true;
    final d = hub.den.device(made);
    return d != null && d.approved && !d.revoked;
  }

  /// Whether the link with [id] is still there and still works (its maker is in the family, the
  /// device it was made on is still let in).
  bool works(String id) {
    final link = FeedLink.fromJson(id, _links[id]);
    return link != null && _works(link);
  }

  /// Whether this family made a link with [secret], working or not: on a Den host, which family
  /// a calendar link asked for at an address that names none belongs to.
  bool holds(String secret) {
    if (!secret.startsWith(prefix) || secret.length > 200) return false;
    final hash = hashToken(secret);
    return _all.any((l) => l.hash == hash);
  }

  /// The link whose secret is [secret], while it [_works]; null otherwise.
  FeedLink? resolve(String secret) {
    if (!secret.startsWith(prefix) || secret.length > 200) return null;
    final hash = hashToken(secret);
    for (final link in _all) {
      if (link.hash == hash) return _works(link) ? link : null;
    }
    return null;
  }

  String _secret() => prefix + base64Url.encode(List.generate(32, (_) => _random.nextInt(256))).replaceAll('=', '');

  String _id() => base64Url.encode(List.generate(12, (_) => _random.nextInt(256)));

  Map<String, Object?> _json(FeedLink link) {
    final made = DateTime.fromMillisecondsSinceEpoch(link.made, isUtc: true);
    return {
      'id': link.id,
      'label': link.label,
      'feed': link.feed,
      'feed_name': link.feed == 'family' || link.shared ? hub.den.family?.name : hub.den.member(link.feed)?.name,
      'made_by': link.member,
      'made_by_name': hub.den.member(link.member)?.name,
      'made': made.toIso8601String(),
      'made_ms': link.made,
    };
  }

  /// `GET /api/v1/feeds`, signed by a parent's own device: the family's calendar links, newest
  /// first, never their addresses.
  Future<Response> list(Request request) async {
    await auth.parent(request, message: 'Only a parent\'s own phone can see calendar links.');
    final links = _all.where(_works).toList()..sort((a, b) => b.made.compareTo(a.made));
    return jsonResponse({'feeds': [for (final l in links) _json(l)]});
  }

  /// `POST /api/v1/feeds` `{"feed": "family" | "shared" | "<memberId>", "label": "Alex's iPhone"}`,
  /// signed by a parent's own device: makes a link and answers its address, this once, as `url`
  /// and as `webcal`. `shared` is the link for another family: Everyone events only.
  Future<Response> create(Request request) async {
    final signed = await auth.withBody(request, limit: 4096);
    final check = DeviceAuth.parentOf(signed.check, message: 'Only a parent\'s own phone can make a calendar link.');
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(signed.body));
    } on FormatException {
      throw ApiError.invalid('The body must be a JSON object.');
    }
    if (json is! Map) throw ApiError.invalid('The body must be a JSON object.');
    final feed = json['feed'] ?? 'family';
    if (feed is! String || (feed != 'family' && feed != FeedLink.sharedFeed && hub.den.member(feed) == null)) {
      throw ApiError.invalid('"feed" must be family, shared or someone in the family.', field: 'feed');
    }
    final label = json['label'];
    if (label is! String || label.trim().isEmpty || label.trim().length > 60) {
      throw ApiError.invalid('"label" must say where the calendar goes, up to 60 characters.', field: 'label');
    }
    final live = _all.where(_works).length;
    if (live >= maxLinks) {
      throw ApiError(409, 'too_many', 'This family already has $maxLinks calendar links. Turn one off first.');
    }
    final secret = _secret();
    final link = FeedLink(
      id: _id(),
      hash: hashToken(secret),
      member: check.actor!.id,
      feed: feed,
      label: label.trim(),
      made: hub.now(),
      device: check.device!.id,
    );
    _links[link.id] = link.toJson();
    await _save();
    hub.log.info('${check.actor!.name} made a calendar link${link.shared ? ' for another family' : ''}');
    final url = urlOf(hub.base(request), '/ics/$secret/${link.file}');
    return jsonResponse({
      ..._json(link),
      'url': url,
      'webcal': url.replaceFirst(RegExp('^https?://'), 'webcal://'),
    }, status: 201);
  }

  /// `DELETE /api/v1/feeds/{id}`, signed by a parent's own device: turns a link off. Calendars
  /// subscribed to it stop updating at their next refresh; a hub watching a shared one hears at
  /// once ([turnedOff]).
  Future<Response> revoke(Request request, String id) async {
    final check = await auth.parent(request, message: 'Only a parent\'s own phone can turn off a calendar link.');
    if (_links.remove(id) == null) throw ApiError.notFound(type: 'feed', message: 'There\'s no calendar link with that id.');
    await _save();
    hub.log.info('${check.actor!.name} turned off a calendar link');
    _turnedOff.add(id);
    return jsonResponse({'ok': true});
  }
}
