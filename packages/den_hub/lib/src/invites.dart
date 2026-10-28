import 'dart:io';
import 'dart:math';

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
/// guess counts: after [maxWrong] in [wrongWindow] the hub stops answering for a while.
class HubInvites {
  /// Creates the invite endpoints for [hub].
  HubInvites(this.hub);

  /// Shared hub context.
  final HubContext hub;

  /// The longest an invite may last.
  static const Duration longest = Duration(days: 7);

  /// Most invites waiting at once.
  static const int maxLive = 50;

  /// Wrong codes allowed in [wrongWindow].
  static const int maxWrong = 10;

  /// How long wrong codes count.
  static const Duration wrongWindow = Duration(minutes: 10);

  static const String _doc = 'invites';

  final Random _random = Random.secure();
  final List<int> _wrong = [];

  /// Adds the invite routes.
  void register(Routes routes) {
    routes
      ..add('POST', '/api/v1/invites', (r, _) => create(r))
      ..add('POST', '/api/v1/invites/redeem', (r, _) => redeem(r));
  }

  Map<String, Object?> get _invites => hub.state.read(_doc);

  Future<void> _save() async {
    await hub.state.save(_doc);
    final dir = hub.config.dataDir;
    if (dir != null) restrictToOwner('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}$_doc.json');
  }

  void _prune(int now) => _invites.removeWhere((_, v) => v is! Map || (v['expires'] as num? ?? 0) <= now);

  String _newCode() => List.generate(4, (_) => wordList[_random.nextInt(wordList.length)]).join(' ');

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
    final problem = await hub.gate.asHub(() => grant.problem(hub.den, expectedContext: context));
    if (problem != null) {
      hub.log.warn('Refused an invite: $problem');
      throw ApiError.denied("Only a parent's own device in this family can invite someone.");
    }
    _prune(now);
    if (_invites.length >= maxLive) {
      throw ApiError(429, 'rate_limited', 'Too many invites are waiting. Try again once some are used or have expired.');
    }
    var code = _newCode();
    while (_invites.containsKey(code)) {
      code = _newCode();
    }
    _invites[code] = {'grant': grant.toJson(), 'expires': expires, 'made': now};
    await _save();
    hub.log.info('A parent made an invite');
    final words = code.split(' ');
    final base = hub.base(request);
    return jsonResponse({
      'code': code,
      'words': words,
      'link': urlOf(base, '/#/join/${words.join('-')}'),
      'expires': DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true).toIso8601String(),
      'expires_ms': expires,
      'member': member,
    }, status: 201);
  }

  /// `POST /api/v1/invites/redeem {code}`: the invite behind four words, for the device about to
  /// join with it over `/ws`.
  Future<Response> redeem(Request request) async {
    if (!hub.ready) throw ApiError.notReady();
    hub.checkFailures(request);
    hub.limit(request, 'pairing', Limits.pairing);
    final now = hub.now();
    _wrong.removeWhere((at) => at <= now - wrongWindow.inMilliseconds);
    if (_wrong.length >= maxWrong) {
      final wait = ((_wrong.first + wrongWindow.inMilliseconds - now) / 1000).ceil();
      throw ApiError.rateLimited(wait < 1 ? 1 : wait, 'Too many wrong codes were tried. Wait ten minutes, then try again.');
    }
    final b = Body(await readJsonObject(request, required: true));
    final code = normalizeCode(b.string('code', required: true, min: 1, max: 200)!);
    if (code == null) {
      throw ApiError.invalid("Those aren't the four words from an invite. Check them against the message.", field: 'code');
    }
    _prune(now);
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
      _wrong.add(now);
      hub.failed(request);
      hub.log.warn('Someone tried words that match no invite');
      throw ApiError.notFound(type: 'invite', message: "That code isn't right, or the invite has expired. Ask for a new invite.");
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
    final member = _memberOf(held.context);
    return jsonResponse({
      'invite': url,
      'member': member,
      'member_name': member == null ? null : hub.den.member(member)?.name,
      'family': hub.den.family?.name,
      'expires': invite.expires.toUtc().toIso8601String(),
      'expires_ms': invite.expires.millisecondsSinceEpoch,
    });
  }
}
