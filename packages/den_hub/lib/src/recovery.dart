import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:shelf/shelf.dart';

import 'body.dart';
import 'context.dart';
import 'device_auth.dart';
import 'edge.dart';
import 'http_util.dart';
import 'setup.dart' show restrictToOwner;

/// The file in `<data>/hub/` holding the secret `den_hub recover` shows the running hub. The hub
/// writes a new one each time it starts; backups leave it out.
const String recoveryCliFile = 'recovery-cli';

/// The hub's state document with live recovery codes (`<data>/hub/recovery-tickets.json`);
/// backups leave it out, since each code lasts 30 minutes.
const String recoveryTicketsDoc = 'recovery-tickets';

/// Why the hub won't make a recovery code: [code] for scripts, [message] for people.
class RecoveryRefused implements Exception {
  /// Creates the refusal.
  const RecoveryRefused(this.code, this.message);

  /// `off` (the family hasn't turned server help on), `nobody` (no such person), `not_parent`,
  /// `not_ready`, or `busy` (too many codes waiting).
  final String code;

  /// Written for the person running the hub.
  final String message;

  @override
  String toString() => message;
}

/// A one-time recovery code for one parent.
class RecoveryTicket {
  /// Creates the ticket.
  const RecoveryTicket({required this.words, required this.member, required this.name, required this.expires, this.link});

  /// The four words.
  final List<String> words;

  /// The parent's member id and name.
  final String member;

  /// The parent's name.
  final String name;

  /// UTC milliseconds.
  final int expires;

  /// `https://<hub>/#/recover/<w>-<w>-<w>-<w>`, when the hub knows its public address.
  final Uri? link;

  /// The API's answer.
  Map<String, Object?> toJson() => {
        'words': words,
        'code': words.join(' '),
        'link': link?.toString(),
        'member': member,
        'member_name': name,
        'expires': DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true).toIso8601String(),
        'expires_ms': expires,
      };
}

/// Server-assisted recovery (ARCHITECTURE.md, "Recovery"), only for a family that turned it on.
///
/// The hub keeps an Ed25519 server recovery key in its data directory (`hub/recovery.json`,
/// owner-only, in backups). A parent's own device asks for its public half
/// (`GET /api/v1/recovery/key`) and writes it into `family.recovery.serverKey`; until then, and
/// after a parent removes it, the key lets nobody in. Whoever runs the hub makes a one-time code
/// for one parent with `den_hub recover --person NAME` (`POST /api/v1/recovery/tickets`, which
/// only the command can call: it shows the secret the hub wrote to [recoveryCliFile]). The new
/// phone redeems the code (`POST /api/v1/recovery/redeem`) with its own key: the hub signs a
/// recovery proof for that parent, that device, a fresh nonce and the code's expiry, and the
/// phone joins over `/ws` with it. Every device sees how it got in, in History and Needs you.
class HubRecovery {
  /// Creates the recovery endpoints for [hub].
  HubRecovery(this.hub, DeviceAuth auth) : _auth = auth {
    _writeCliSecret();
  }

  /// For `den_hub recover` while no hub runs on the data directory: makes codes the hub keeps in
  /// its state for when it starts, and serves nothing.
  HubRecovery.offline(this.hub) : _auth = null;

  /// Shared hub context.
  final HubContext hub;

  final DeviceAuth? _auth;

  /// How long a code works.
  static const Duration ticketLife = Duration(minutes: 30);

  /// Most codes waiting at once.
  static const int maxLive = 10;

  /// Wrong codes one client may try in [wrongWindow].
  static const int maxWrong = 10;

  /// Wrong codes all clients together may try in [wrongWindow]: twenty clients' worth, so one
  /// can't use them up and keep a parent out, against at most [maxLive] codes of 44 bits that
  /// last half an hour.
  static const int wrongCeiling = 200;

  /// How long wrong codes count.
  static const Duration wrongWindow = Duration(minutes: 10);

  static const String _keyDoc = 'recovery';

  final Random _random = Random.secure();
  final WrongGuesses _wrong = WrongGuesses(perClient: maxWrong, ceiling: wrongCeiling, window: wrongWindow);
  String? _cliSecret;

  /// Adds the recovery routes.
  void register(Routes routes) {
    routes
      ..add('GET', '/api/v1/recovery/key', (r, _) => key(r))
      ..add('POST', '/api/v1/recovery/tickets', (r, _) => tickets(r))
      ..add('POST', '/api/v1/recovery/redeem', (r, _) => redeem(r));
  }

  String? get _dir => hub.config.dataDir;

  void _writeCliSecret() {
    final dir = _dir;
    if (dir == null) return;
    final secret = _cliSecret = b64e(randomBytes(32));
    try {
      final file = File('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}$recoveryCliFile');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$secret\n', flush: true);
      restrictToOwner(file.path);
    } on Object catch (e) {
      _cliSecret = null;
      hub.log.warn('Couldn\'t save the recovery command\'s secret: ${e.runtimeType}');
    }
  }

  Future<void> _save(String doc) async {
    await hub.state.save(doc);
    final dir = _dir;
    if (dir != null) restrictToOwner('$dir${Platform.pathSeparator}hub${Platform.pathSeparator}$doc.json');
  }

  /// The hub's server recovery key, made and kept on first use.
  Future<RecoveryKey> serverKey() async {
    final doc = hub.state.read(_keyDoc);
    final seed = _bytes(doc['seed']);
    if (seed != null && seed.length == 32) return RecoveryKey.fromSeed(seed);
    final made = await RecoveryKey.generate();
    doc
      ..clear()
      ..['seed'] = b64e(await made.seed())
      ..['key'] = made.publicKey
      ..['made'] = hub.now();
    await _save(_keyDoc);
    hub.log.info('Made this hub\'s server recovery key');
    return made;
  }

  /// The public half of the hub's key, when it has made one, without making it.
  String? get _publicKey {
    final key = hub.state.read(_keyDoc)['key'];
    return key is String ? key : null;
  }

  /// Whether the family lets this hub help: its `recovery.serverKey` is this hub's key.
  bool get on {
    final family = hub.den.family;
    final mine = _publicKey;
    return family != null && mine != null && serverRecoveryKeyOf(family) == mine;
  }

  /// `GET /api/v1/recovery/key`, signed by a parent's own device: the public half of the hub's
  /// server recovery key, for that device to write into `family.recovery.serverKey`, and
  /// whether the family has.
  Future<Response> key(Request request) async {
    await _auth!.parent(request, message: 'Only a parent\'s own phone can let the hub help.');
    if (_dir == null) {
      throw ApiError(409, 'unavailable', 'This hub keeps nothing on disk, so it can\'t help anyone get back in.');
    }
    final key = await serverKey();
    return jsonResponse({'key': key.publicKey, 'on': on});
  }

  /// `POST /api/v1/recovery/tickets {person}`, from `den_hub recover` on the hub's own machine:
  /// a one-time code for that parent.
  Future<Response> tickets(Request request) async {
    final secret = _cliSecret;
    final given = request.headers['x-den-recovery-secret'];
    final client = hub.client(request);
    if (secret == null ||
        given == null ||
        !_same(utf8.encode(given.trim()), utf8.encode(secret)) ||
        !(client?.isLoopback ?? false)) {
      hub.failed(request);
      throw ApiError.denied('Only den_hub recover, on the hub\'s own machine, can make a recovery code.');
    }
    final b = Body(await readJsonObject(request, required: true));
    final person = b.string('person', required: true, min: 1, max: 100)!;
    try {
      final ticket = await issue(person);
      return jsonResponse(ticket.toJson(), status: 201);
    } on RecoveryRefused catch (e) {
      final status = switch (e.code) {
        'off' => 403,
        'busy' => 429,
        'not_ready' => 503,
        _ => 400,
      };
      throw ApiError(status, e.code, e.message);
    }
  }

  /// Makes a code for [person] (their name in Den), good once for [ticketLife]. Throws
  /// [RecoveryRefused] while the family hasn't turned server help on, and for anyone who isn't
  /// one of its parents.
  Future<RecoveryTicket> issue(String person) async {
    if (!hub.ready) throw const RecoveryRefused('not_ready', 'This hub isn\'t part of a family yet.');
    final wanted = person.trim().toLowerCase();
    final named = [for (final m in hub.den.members) if (m.name.trim().toLowerCase() == wanted) m];
    final parents = [for (final m in hub.den.members) if (m.isParent) m.name].join(', ');
    if (named.isEmpty) throw RecoveryRefused('nobody', 'Nobody in this family is called "$person". Parents: $parents.');
    if (named.length > 1) throw RecoveryRefused('nobody', 'More than one person is called "$person".');
    final member = named.single;
    if (!member.isParent) {
      throw RecoveryRefused('not_parent', '${member.name} isn\'t a parent. Recovery lets in a phone only for a parent: $parents.');
    }
    if (!on) {
      throw RecoveryRefused(
        'off',
        'This family hasn\'t turned on server help, so the hub can\'t let ${member.name}\'s new phone in.\n'
            'A parent can turn it on in Den on their own phone: Settings, Family, "Let the hub help us get back in".\n'
            'Without it, ${member.name} can get back in with their 12 recovery words: on the new phone, open Den '
            'and choose "I lost my phone".',
      );
    }
    final now = hub.now();
    final tickets = hub.state.read(recoveryTicketsDoc);
    _prune(tickets, now);
    if (tickets.length >= maxLive) throw const RecoveryRefused('busy', 'Too many recovery codes are waiting. Wait half an hour.');
    var words = _newWords();
    while (tickets.containsKey(_hash(words))) {
      words = _newWords();
    }
    final expires = now + ticketLife.inMilliseconds;
    tickets[_hash(words)] = {'member': member.id, 'expires': expires, 'made': now};
    await _save(recoveryTicketsDoc);
    hub.log.warn('Made a one-time recovery code for ${member.name}, good for 30 minutes');
    final public = hub.config.publicUrl;
    return RecoveryTicket(
      words: words,
      member: member.id,
      name: member.name,
      expires: expires,
      link: public == null ? null : Uri.parse(urlOf(public, '/#/recover/${words.join('-')}')),
    );
  }

  List<String> _newWords() => List.generate(spokenCodeWords, (_) => wordList[_random.nextInt(wordList.length)]);

  /// Codes are kept as hashes, like tokens.
  static String _hash(List<String> words) => hashToken('den/recovery-code/v1|${words.join(' ')}');

  static List<int>? _bytes(Object? text) {
    if (text is! String) return null;
    try {
      return b64d(text);
    } on FormatException {
      return null;
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static void _prune(Map<String, Object?> tickets, int now) =>
      tickets.removeWhere((_, v) => v is! Map || (v['expires'] as num? ?? 0) <= now);

  /// `POST /api/v1/recovery/redeem {code, pubkey}`: the new phone's key for the four words; the
  /// hub signs a recovery proof for that parent and that device, and gives the phone an invite
  /// to join over `/ws` with it. A code works for one device: asked again by the same device
  /// it answers the same proof. Wrong codes count like an invite's.
  Future<Response> redeem(Request request) async {
    if (!hub.ready) throw ApiError.notReady();
    hub.checkFailures(request);
    hub.limit(request, 'pairing', Limits.pairing);
    final now = hub.now();
    final client = hub.clientOf(request);
    final wait = _wrong.wait(client, now);
    if (wait != null) {
      throw ApiError.rateLimited(
          wait.seconds,
          wait.all
              ? 'Too many wrong codes were tried. Wait a few minutes, then try again.'
              : 'Too many wrong codes from here. Wait ten minutes, then try again.');
    }
    final b = Body(await readJsonObject(request, required: true));
    final code = normalizeCode(b.string('code', required: true, min: 1, max: 200)!);
    final pubkey = b.string('pubkey', required: true, min: 20, max: 100)!;
    if (code == null) {
      throw ApiError.invalid('Those aren\'t the four words from whoever runs your hub.', field: 'code');
    }
    if (_bytes(pubkey)?.length != 32) throw ApiError.invalid('That isn\'t a device key.', field: 'pubkey');
    final tickets = hub.state.read(recoveryTicketsDoc);
    _prune(tickets, now);
    final hash = _hash(code.split(' '));
    final ticket = tickets[hash];
    if (ticket is! Map || (ticket['device'] != null && ticket['device'] != pubkey)) {
      _wrong.add(client, now);
      hub.failed(request);
      hub.log.warn('Someone tried words that match no recovery code');
      throw ApiError.notFound(type: 'recovery', message: 'Those words aren\'t right, or they have expired or been used. Ask for new ones.');
    }
    final member = hub.den.member(ticket['member'] as String? ?? '');
    if (member == null || !member.isParent) {
      tickets.remove(hash);
      await _save(recoveryTicketsDoc);
      throw ApiError.notFound(type: 'recovery', message: 'That code no longer works. Ask for a new one.');
    }
    if (!on) {
      tickets.remove(hash);
      await _save(recoveryTicketsDoc);
      throw ApiError.denied('Your family turned off server help since this code was made, so the hub can\'t let you in.');
    }
    final expires = (ticket['expires'] as num).toInt();
    var proof = RecoveryProof.parse(ticket['proof']);
    if (proof == null) {
      proof = await (await serverKey()).prove(
        family: hub.den.familyId!,
        kind: RecoveryKind.hub,
        member: member.id,
        devicePubkey: pubkey,
        expires: expires,
      );
      tickets[hash] = {...ticket, 'device': pubkey, 'proof': proof.toJson()};
      await _save(recoveryTicketsDoc);
      hub.log.warn('A new phone for ${member.name} redeemed a recovery code');
    }
    final invite = Invite.create(
      familyId: hub.den.familyId!,
      founderPubkey: hub.den.founderPubkey!,
      inviterDevice: hub.den.deviceId,
      inviterPubkey: hub.den.keys.pubkey,
      validFor: Duration(milliseconds: max(expires - now, 60000)),
    );
    hub.node.invites.add(invite);
    return jsonResponse({
      'invite': invite.toUrl(),
      'member': member.id,
      'member_name': member.name,
      'family': hub.den.family?.name,
      'proof': proof.toJson(),
      'expires': DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true).toIso8601String(),
      'expires_ms': expires,
    });
  }
}
