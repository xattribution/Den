import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:den_core/den_core.dart' show deviceIdOf, inviteKeyIdOf;
import 'package:den_net/den_net.dart';
import 'package:shelf/shelf.dart';

import 'body.dart';
import 'context.dart';
import 'edge.dart';
import 'http_util.dart';
import 'setup.dart' show restrictToOwner;

/// Invites a parent sends as a message (`/api/v1/invites`), so someone can join from anywhere,
/// later, with no camera and with the parent's phone asleep.
///
/// A parent's device signs an invite naming this hub ([InviteGrant], context `invite`, or
/// `invite:<memberId>` for an invite meant for one person). The hub keeps it under four random
/// words from Den's word list until the invite expires (a week at most), in its data directory,
/// so a restart doesn't lose it. Whoever has the words gets the invite back and joins over
/// `/ws`, pinning the hub's key; a parent still approves the device that asks. Every wrong
/// guess counts: after [maxWrong] in [wrongWindow] from one client that client waits, and after
/// [wrongCeiling] from everyone together everyone does.
///
/// An invite is for one person, once: it stops working when a parent approves a device that
/// joined with it, or once [maxJoins] devices have joined with it and wait (or were turned away).
/// The hub learns which device used which invite from its [HubInviteBook].
///
/// The app's own invites pick their four words on the parent's phone and give the hub only
/// their slot (den_net's `InviteWords.slot`, a stretch of the words the hub can't run back), so
/// the hub keeps the invite without knowing the words. Such an invite may carry the public half
/// of an invite key (den_core's invite_keys.dart) the parent's phone wrote into the family's
/// log: then whoever has the words lets their device in at once, and the hub checks first that
/// the key reached it. Words typed into an older app still work: the hub stretches them itself.
/// Words the hub picks itself (for an older app that sends no slot) are kept with their slot
/// too, so the app asks for every invite by its slot alone and never needs to send the words.
class HubInvites {
  /// Creates the invite endpoints for [hub].
  HubInvites(this.hub) {
    final book = hub.node.invites;
    if (book is HubInviteBook) book.onRedeem = _joined;
  }

  /// Shared hub context.
  final HubContext hub;

  /// The longest an invite may last.
  static const Duration longest = Duration(days: 7);

  /// Most invites waiting at once.
  static const int maxLive = 50;

  /// Wrong codes one client may try in [wrongWindow].
  static const int maxWrong = 10;

  /// Wrong codes all clients together may try in [wrongWindow]: twenty clients' worth, so one
  /// can't use them up, and still under 30,000 a day against 50 invites of 44 bits each.
  static const int wrongCeiling = 200;

  /// How long wrong codes count.
  static const Duration wrongWindow = Duration(minutes: 10);

  /// Devices that may join with one invite before a parent approves one of them: the person may
  /// try a second device, or start Den over, before anyone approves; three covers that, and a
  /// code that leaked puts no more than three requests in front of a parent.
  static const int maxJoins = 3;

  static const String _doc = 'invites';

  final Random _random = Random.secure();
  late final WrongGuesses _own = WrongGuesses(perClient: maxWrong, ceiling: wrongCeiling, window: wrongWindow);

  /// Wrong words, counted for the whole host when the hub is one family of a Den host.
  WrongGuesses get _wrong => hub.host?.inviteGuesses ?? _own;

  /// Adds the invite routes.
  void register(Routes routes) {
    routes
      ..add('POST', '/api/v1/invites', (r, _) => create(r))
      ..add('POST', '/api/v1/invites/redeem', (r, _) => redeem(r));
  }

  /// Whether this family keeps a live invite under [key]: four words, or `slot:<hex>` (the
  /// slot of an invite kept by its words included).
  bool holds(String key) {
    if (!hub.ready) return false;
    _prune(hub.now());
    return _invites.containsKey(key) || _wordsFor(key) != null;
  }

  /// The words an invite the hub picked is kept under, by its slot (`slot:<hex>`).
  String? _wordsFor(String key) {
    if (!key.startsWith('slot:')) return null;
    for (final e in _invites.entries) {
      final v = e.value;
      if (v is Map && v['slot'] == key) return e.key;
    }
    return null;
  }

  /// Whether [key] is taken here or by another family on the host: invite words are unique per
  /// host, so words typed at any family's address find one invite.
  bool _taken(String key) => _invites.containsKey(key) || (hub.host?.inviteTaken(key) ?? false);

  Map<String, Object?> get _invites => hub.state.read(_doc);

  Future<void> _save() async {
    await hub.state.save(_doc);
    final dir = hub.config.dataDir;
    if (dir != null) restrictToOwner('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}$_doc.json');
  }

  void _prune(int now) => _invites.removeWhere((_, v) => v is! Map || (v['expires'] as num? ?? 0) <= now);

  String _newCode() => List.generate(4, (_) => wordList[_random.nextInt(wordList.length)]).join(' ');

  static final RegExp _slotRe = RegExp(r'^[0-9a-f]{64}$');

  /// Whether the hub keeps any invite under a slot, so typed words are worth stretching.
  bool get _hasSlots => _invites.keys.any((k) => k.startsWith('slot:'));

  /// Whether the invite key [key] lets a device in now, by this hub's replica.
  bool _preapproved(Object? key) {
    if (key is! String) return false;
    final id = inviteKeyIdOf(key);
    final record = id == null ? null : hub.den.inviteKey(id);
    return record != null && record.key == key && record.liveAt(hub.now()) && hub.den.inviteUses(record) > 0;
  }

  /// Who an invite's context names: null for anyone, the member id after `invite:`.
  static String? _memberOf(String context) => context.startsWith('invite:') ? context.substring('invite:'.length) : null;

  /// `POST /api/v1/invites`: a parent's signed invite grant; answers the four words and a link.
  Future<Response> create(Request request) async {
    if (!hub.ready) throw ApiError.notReady();
    final json = await readJsonObject(request, required: true);
    final InviteGrant grant;
    try {
      grant = InviteGrant.fromJson(json);
    } on FormatException {
      throw ApiError.invalid("That isn't an invite from the Den app.");
    }
    final context = grant.context;
    final member = _memberOf(context);
    if (context != 'invite' && member == null) throw ApiError.invalid("That invite isn't for joining the family.");
    if (member != null && hub.den.member(member) == null) {
      throw ApiError.invalid("There's nobody like that in the family.", field: 'member');
    }
    final now = hub.now();
    final expires = grant.invite.expires.millisecondsSinceEpoch;
    if (expires - now > longest.inMilliseconds + const Duration(minutes: 5).inMilliseconds) {
      throw ApiError.invalid('An invite lasts a week at most.');
    }
    final slot = json['slot'];
    final key = json['key'];
    if (slot != null && (slot is! String || !_slotRe.hasMatch(slot))) {
      throw ApiError.invalid("That invite's slot isn't one the Den app makes.", field: 'slot');
    }
    if (key != null && (key is! String || slot == null || member == null)) {
      throw ApiError.invalid('An invite that lets someone in at once names them and comes with its slot.', field: 'key');
    }
    final problem = await hub.gate.asHub(() => grant.problem(hub.den, expectedContext: context));
    if (problem != null) {
      hub.log.warn('Refused an invite: $problem');
      throw ApiError.denied("Only a parent's own device in this family can invite someone.");
    }
    if (key is String) {
      final id = inviteKeyIdOf(key);
      final record = id == null ? null : hub.den.inviteKey(id);
      // The parent's phone wrote the key a moment ago; it may not have synced yet.
      if (record == null) throw ApiError(409, 'not_synced', "The invite hasn't reached the hub yet. Try again in a moment.");
      if (record.member != member || record.key != key || !record.liveAt(now)) {
        throw ApiError.invalid("That invite's key isn't one the family made for them.", field: 'key');
      }
    }
    _prune(now);
    if (_invites.length >= maxLive) {
      throw ApiError(429, 'rate_limited', 'Too many invites are waiting. Try again once some are used or have expired.');
    }
    final base = hub.base(request);
    if (slot is String) {
      final at = 'slot:$slot';
      if (_taken(at)) throw ApiError(409, 'conflict', 'That invite is already waiting. Make a new one.');
      _invites[at] = {'grant': grant.toJson(), 'url': grant.invite.toUrl(), 'expires': expires, 'made': now, 'key': ?key};
      await _save();
      hub.log.info(key == null ? 'A parent made an invite' : 'A parent made an invite that lets someone in at once');
      return jsonResponse({
        'slot': slot,
        'base': base.toString(),
        'expires': DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true).toIso8601String(),
        'expires_ms': expires,
        'member': member,
        'preapproved': key != null,
      }, status: 201);
    }
    var code = _newCode();
    while (_taken(code)) {
      code = _newCode();
    }
    // Kept with its slot as well, so an app that asks by slot alone finds it.
    final alias = 'slot:${await InviteWords.slot(code)}';
    _invites[code] = {'grant': grant.toJson(), 'url': grant.invite.toUrl(), 'expires': expires, 'made': now, 'slot': alias};
    await _save();
    hub.log.info('A parent made an invite');
    final words = code.split(' ');
    return jsonResponse({
      'code': code,
      'words': words,
      'link': urlOf(base, '/#/join/${words.join('-')}'),
      'expires': DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true).toIso8601String(),
      'expires_ms': expires,
      'member': member,
    }, status: 201);
  }

  /// The devices that joined with the invite [entry] holds.
  static List<String> _joins(Map<Object?, Object?> entry) => [...((entry['joins'] as List?) ?? const []).whereType<String>()];

  /// Whether [entry]'s invite has done its job: its key let in what it may, a parent approved a
  /// device that joined with it, or [maxJoins] devices did.
  bool _usedUp(Map<Object?, Object?> entry) {
    // An invite that lets someone in at once is used up once its key let in what it may.
    final key = entry['key'];
    final record = key is String ? hub.den.inviteKey(inviteKeyIdOf(key) ?? '') : null;
    if (record != null && hub.den.inviteUses(record) <= 0) return true;
    final joins = _joins(entry);
    return joins.length >= maxJoins || joins.any((id) => hub.den.device(id)?.approved ?? false);
  }

  /// [HubInviteBook]: the device with [pubkey] proved [invite] on `/ws`.
  void _joined(Invite invite, String pubkey) {
    final device = deviceIdOf(pubkey);
    if (device == null) return;
    final url = invite.toUrl();
    for (final entry in _invites.values) {
      if (entry is! Map || entry['url'] != url) continue;
      final joins = _joins(entry);
      if (!joins.contains(device)) entry['joins'] = [...joins, device];
      unawaited(_save().catchError((Object _) {}));
      return;
    }
  }

  /// `POST /api/v1/invites/redeem {code}` or `{slot}`: the invite behind four words (or the slot
  /// they stretch to), for the device about to join with it over `/ws`, while it hasn't been
  /// used ([maxJoins]); `404` once it has. Says whether it lets the device in at once
  /// (`preapproved`, with the invite key's public half as `key`).
  Future<Response> redeem(Request request) => redeemAcross(request, [this]);

  /// [redeem] across [books], every family's on a Den host: words are unique per host, so the
  /// words someone types at any family's address find their invite, whichever family made it.
  /// The limits and wrong-word counts are the host's, checked before anything is looked up (and
  /// before typed words are stretched); the family that keeps the invite answers.
  static Future<Response> redeemAcross(Request request, List<HubInvites> books) async {
    final ready = [for (final b in books) if (b.hub.ready) b];
    if (ready.isEmpty) throw ApiError.notReady();
    // Limits, failed tries and wrong words are the host's, shared by every family on it, so any
    // family's context counts them the same.
    final first = ready.first;
    final hub = first.hub;
    hub.checkFailures(request);
    hub.limit(request, 'pairing', Limits.pairing);
    final now = hub.now();
    final client = hub.clientOf(request);
    final wait = first._wrong.wait(client, now);
    if (wait != null) {
      throw ApiError.rateLimited(
          wait.seconds,
          wait.all
              ? 'Too many wrong codes were tried. Wait a few minutes, then try again.'
              : 'Too many wrong codes from here. Wait ten minutes, then try again.');
    }
    final b = Body(await readJsonObject(request, required: true));
    final slot = b.string('slot', max: 64);
    String code;
    if (slot != null) {
      if (!_slotRe.hasMatch(slot)) throw ApiError.invalid("That isn't an invite's slot.", field: 'slot');
      code = 'slot:$slot';
    } else {
      final typed = normalizeCode(b.string('code', required: true, min: 1, max: 200)!);
      if (typed == null) {
        throw ApiError.invalid("Those aren't the four words from an invite. Check them against the message.", field: 'code');
      }
      code = typed;
    }
    var holders = [for (final book in ready) if (book.holds(code)) book];
    // Words typed into an app that doesn't stretch them: the hub does, for an invite it keeps by
    // its slot (one Argon2id run, so only after the limits above let the client try).
    if (slot == null && holders.isEmpty && ready.any((book) => book._hasSlots)) {
      code = 'slot:${await InviteWords.slot(code)}';
      holders = [for (final book in ready) if (book.holds(code)) book];
    }
    // Unique per host; two holding the same words would be a mistake, and neither answers.
    if (holders.length != 1) {
      first._wrong.add(client, now);
      hub.failed(request);
      hub.log.warn('Someone tried words that match no invite');
      throw ApiError.notFound(type: 'invite', message: "That code isn't right, or the invite has expired. Ask for a new invite.");
    }
    final holder = holders.single;
    return holder._answer(request, holder._wordsFor(code) ?? code, client, now);
  }

  /// The invite this family keeps under [code], for [redeemAcross].
  Future<Response> _answer(Request request, String code, String client, int now) async {
    final entry = _invites[code];
    InviteGrant? grant;
    if (entry is Map && entry['grant'] is Map) {
      try {
        grant = InviteGrant.fromJson((entry['grant'] as Map).cast<String, Object?>());
      } on FormatException {
        grant = null;
      }
    }
    if (grant == null) {
      _wrong.add(client, now);
      hub.failed(request);
      hub.log.warn('Someone tried words that match no invite');
      throw ApiError.notFound(type: 'invite', message: "That code isn't right, or the invite has expired. Ask for a new invite.");
    }
    if (_usedUp(entry as Map)) {
      _invites.remove(code);
      await _save();
      hub.log.info('An invite that was already used was asked for again');
      throw ApiError.notFound(type: 'invite', message: 'That invite was used already. Ask for a new one.');
    }
    // The parent who made it may have left, or lost their device, since.
    final held = grant;
    final problem = await hub.gate.asHub(() => held.problem(hub.den, expectedContext: held.context));
    if (problem != null) {
      _invites.remove(code);
      await _save();
      hub.log.warn('Dropped an invite that no longer holds: $problem');
      throw ApiError.notFound(type: 'invite', message: 'That invite no longer works. Ask for a new one.');
    }
    final invite = held.invite;
    final url = invite.toUrl();
    if (!hub.node.invites.live.any((i) => i.toUrl() == url)) hub.node.invites.add(invite);
    entry['url'] ??= url;
    final member = _memberOf(held.context);
    final key = entry['key'];
    return jsonResponse({
      'invite': url,
      'key': ?(key is String ? key : null),
      'preapproved': _preapproved(key),
      'member': member,
      'member_name': member == null ? null : hub.den.member(member)?.name,
      // Their color and picture, to show whose device this becomes before it holds the family.
      'member_marker': member == null ? null : hub.den.member(member)?.marker.name,
      'member_picture': member == null ? null : hub.den.member(member)?.picture,
      'family': hub.den.family?.name,
      'expires': invite.expires.toUtc().toIso8601String(),
      'expires_ms': invite.expires.millisecondsSinceEpoch,
    });
  }
}

/// The hub's book of live invites (den_net's [InviteBook]), telling [HubInvites] which device
/// proved which invite, so an invite sent by message works for one person.
class HubInviteBook extends InviteBook {
  /// Called when a device with the given key proves an invite.
  void Function(Invite invite, String pubkey)? onRedeem;

  @override
  Future<Invite?> redeem(String joinerPubkey, String proof) async {
    final invite = await super.redeem(joinerPubkey, proof);
    if (invite != null) onRedeem?.call(invite, joinerPubkey);
    return invite;
  }
}
