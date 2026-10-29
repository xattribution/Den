import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' as net show DenLink, DenLinkKind, Invite;

import '../../../app/household.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/den_network.dart';
import '../../../platform/sync/hub_client.dart';
import '../../../platform/sync/hub_push.dart';
import '../../../platform/sync/net_pairing.dart';
import '../../../platform/sync/pairing.dart';
import '../../../platform/web/web_app.dart';

/// What a pasted invite is, for a device already in a family: where to join it, or why it can't
/// be joined from here.
sealed class PastedInvite {
  const PastedInvite();

  /// Reads [text] (the link alone, the whole message, or four words). Whether the family is on
  /// this server is for the server to say: on a Den host every family has its own address, and
  /// the app asks its own address about any of them ([AnotherFamilyPairing]).
  static PastedInvite read(String text) {
    final link = net.DenLink.parse(text);
    return switch (link?.kind) {
      null => const PasteProblem("There's no invite on the clipboard. Copy the whole invite, then tap Paste an invite again."),
      net.DenLinkKind.group => const PasteProblem('Invites to a group of families come with a later version of Den.'),
      net.DenLinkKind.setup => const PasteProblem("That's a link to set up a new hub, not an invite to a family."),
      net.DenLinkKind.recover => const PasteProblem("That's a link to get back into a family on a new phone, not an invite."),
      net.DenLinkKind.family => JoinRoute(words: link!.words!, hub: link.hub),
    };
  }

  /// Whether [a] and [b] are the same server: scheme, name and port.
  static bool sameServer(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host.toLowerCase() == b.host.toLowerCase() && _port(a) == _port(b);

  static int _port(Uri u) => u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80);

  /// Why an invite from another server can't be joined in this web app yet, and the way that
  /// works today (FAMILY-LINKS-PLAN §5.1, until families on different servers come).
  static String otherServer(Uri hub) =>
      "That family's Den is on another server (${hub.host}), and Den here holds families on this server only for now. "
      'Open the invite in Safari and add that Den to your Home Screen too.';
}

/// An invite to a family: join it at `/families/join`.
final class JoinRoute extends PastedInvite {
  const JoinRoute({required this.words, this.hub});

  final String words;

  /// The hub's address, when the invite carried its link.
  final Uri? hub;

  String get location => Uri(path: '/families/join', queryParameters: {
        'code': words.replaceAll(' ', '-'),
        if (hub != null) 'hub': hub.toString(),
      }).toString();
}

/// Not an invite this device can join: why, in words for people.
final class PasteProblem extends PastedInvite {
  const PasteProblem(this.message);
  final String message;
}

/// The join screen's pairing while a device already in a family joins another one beside it
/// (`/families/join`, FAMILY-LINKS-PLAN §5.1). It asks the hub which family the invite is for,
/// starts that family's own engine with new keys of its own ([Household.prepare]), joins through
/// it, and on success the household takes it in and shows it ([Household.adopt]); anything that
/// fails takes the new engine away again. A family this device holds already is refused: one
/// engine per family.
///
/// In the web app everything goes through the server the app came from (several families at one
/// origin share the app, its storage and its push subscription): a Den host finds an invite
/// whichever family's address its link names, and says it has none for a family on another
/// server, which the app then says plainly (until families on different servers come, phase 9).
/// The native apps join a family on any server, at its link's address.
class AnotherFamilyPairing extends PairingService {
  AnotherFamilyPairing(this.home, {Uri? servedBy, bool? web})
      : _servedBy = servedBy,
        _web = web ?? Capabilities.web;

  static final Expando<AnotherFamilyPairing> _kept = Expando('AnotherFamilyPairing');

  /// The one for [home], kept while the household lasts, so the join screen keeps it across
  /// rebuilds (the household changes as the new family comes in).
  static AnotherFamilyPairing of(Household home) => _kept[home] ??= AnotherFamilyPairing(home);

  final Household home;
  final Uri? _servedBy;
  final bool _web;

  /// The family being joined, while it is.
  FamilyLog? _joining;

  /// The pairing of the family the device shows, which asks the hub about invites.
  NetPairing get _probe {
    final pairing = home.active.pairing;
    if (pairing is NetPairing) return pairing;
    throw const PairingException("This device can't reach a hub to join another family.");
  }

  /// The server this web app came from.
  Uri? get _page {
    final base = _servedBy ?? (_web ? Uri.base : null);
    if (base == null || base.host.isEmpty) return null;
    return Uri(scheme: base.scheme, host: base.host, port: base.hasPort ? base.port : null);
  }

  /// Where the invite is asked about: on the web the app's own server, always; in the native
  /// apps the link's address, or for words alone the server the family shown is on, where a Den
  /// host keeps every family's invites.
  Future<String?> _hubFor(String? hubUrl) async {
    final typed = hubUrl == null || hubUrl.trim().isEmpty ? null : HubClient.baseFor(hubUrl);
    final page = _page;
    if (_web) return page?.toString();
    if (typed != null) return typed.toString();
    if (page != null) return page.toString();
    final bases = await home.active.network?.hubBases() ?? const <Uri>[];
    return bases.firstOrNull?.toString();
  }

  /// The family [words] invite to, refused when this device holds it already. In the web app,
  /// an invite this server doesn't know whose link names another server is that family's Den
  /// elsewhere.
  Future<InviteTarget> _target(String words, String? hub, String? linked) async {
    final InviteTarget target;
    try {
      target = await _probe.inviteTarget(words, hubUrl: hub);
    } on PairingException catch (e) {
      final link = linked == null || linked.trim().isEmpty ? null : HubClient.baseFor(linked);
      final page = _page;
      if (_web && e.reason == PairingException.unknownCode && link != null && page != null && !PastedInvite.sameServer(link, page)) {
        throw PairingException(PastedInvite.otherServer(link), reason: PairingException.unknownCode);
      }
      rethrow;
    }
    final here = home.byId(target.familyId);
    if (here != null) throw PairingException('This device is in ${here.name} already.');
    return target;
  }

  @override
  Future<InvitePeek> peekInvite(String words, {String? hubUrl}) async {
    final hub = await _hubFor(hubUrl);
    await _target(words, hub, hubUrl);
    return _probe.peekInvite(words, hubUrl: hub);
  }

  @override
  Future<JoinTicket> joinWithInvite(
    String words, {
    String? hubUrl,
    required String Function(String? forName) deviceName,
    required DeviceKind kind,
  }) async {
    final hub = await _hubFor(hubUrl);
    final target = await _target(words, hub, hubUrl);
    return _join(target.familyId, target.base, target.familyName, (pairing) async {
      _probe.shareRedeemed(pairing);
      return pairing.joinWithInvite(words, hubUrl: hub, deviceName: deviceName, kind: kind);
    });
  }

  @override
  Future<JoinTicket> joinWithQr(String uri, {required String deviceName, required DeviceKind kind}) async {
    final net.Invite invite;
    try {
      invite = await net.Invite.parse(uri);
    } on Object {
      throw const PairingException("That isn't a Den invite, or it has expired. Ask for a new code.");
    }
    final here = home.byId(invite.familyId);
    if (here != null) throw PairingException('This device is in ${here.name} already.');
    final sync = invite.hubs.firstOrNull;
    final base = sync == null ? null : HubClient.baseFor(sync.toString());
    return _join(invite.familyId, base, null, (pairing) => pairing.joinWithQr(uri, deviceName: deviceName, kind: kind));
  }

  /// Starts the family's own engine, joins through it, and takes it in; takes it away again when
  /// joining fails.
  Future<JoinTicket> _join(String familyId, Uri? hub, String? name, Future<JoinTicket> Function(NetPairing pairing) send) async {
    if (_joining != null) throw const PairingException('Already joining a family. Wait a moment.');
    final FamilyLog log;
    try {
      log = await home.prepare(familyId, hub: hub, label: name);
    } on StateError catch (e) {
      throw PairingException(e.message);
    }
    _joining = log;
    try {
      final pairing = log.pairing;
      if (pairing is! NetPairing) throw const PairingException("This device can't reach that family's hub.");
      final ticket = await send(pairing);
      if (ticket.familyId != familyId) throw const PairingException('That invite led to another family. Ask for a new one.');
      await home.adopt(log);
      if (_web) unawaited(MembershipActions.shareReminders(log));
      return ticket;
    } catch (_) {
      await home.discard(log);
      rethrow;
    } finally {
      _joining = null;
    }
  }

  @override
  Future<JoinTicket> joinWithCode(String words, {String? hubUrl, required String deviceName, required DeviceKind kind}) async =>
      throw const PairingException(
        'To join another family, use the invite one of its parents sent you: copy the whole message, then Paste the invite.',
      );

  @override
  Stream<JoinStatus> get joinStatus => _joining?.pairing?.joinStatus ?? const Stream.empty();

  @override
  Future<String> createInviteQr() async => throw const PairingException('Invite from the family you want to invite to.');

  @override
  Future<SpokenCode> createSpokenCode() async => throw const PairingException('Invite from the family you want to invite to.');

  @override
  Stream<List<PendingJoin>> get pendingJoins => Stream.value(const []);
}

/// Leaving a family on this device (the owner's decision: a person leaves, nobody removes
/// another family). Only while the device holds another family: the last one stays, so leaving
/// never empties Den or strands a family's only parent device by accident; a device in one
/// family leaves the way it always could (its parents remove it, or it starts over).
abstract final class MembershipActions {
  /// Whether [log]'s family can be left on this device now.
  static bool canLeave(Household home, FamilyLog log) =>
      home.families.length > 1 && home.families.contains(log);

  /// Leaves [log]'s family on this device: the device takes itself out of the family (a device
  /// may remove itself, so the family's other devices see it gone and History says so), waits a
  /// moment for that to reach the family's hub, then closes the family's engine and deletes its
  /// log, keys and settings from this device. Another family shows.
  static Future<void> leave(Household home, FamilyLog log, {Duration flush = const Duration(seconds: 2)}) async {
    if (!canLeave(home, log)) throw StateError('This is the only family on this device');
    final den = log.den;
    if (den.isApproved && !(den.thisDevice?.revoked ?? true)) {
      try {
        await den.revokeDevice(den.deviceId);
        await _sent(log.network, flush);
      } on Object {
        // Out of reach or refused: the family's parents can still remove this device; this
        // device forgets the family either way.
      }
    }
    await home.remove(log);
  }

  /// In the web app, once [joined] lets this device in: when this browser's reminders already
  /// come through the key the families on this server share, the family gets the same
  /// subscription, with no tap (the browser's subscription stays as it is). A browser whose
  /// reminders come through one family's own key keeps them; Settings offers to turn them on from
  /// every family, which takes a tap. Best effort.
  static Future<void> shareReminders(FamilyLog joined, {Duration wait = const Duration(minutes: 2)}) async {
    final network = joined.network;
    if (network == null) return;
    final until = DateTime.now().add(wait);
    while (!joined.den.isApproved || network.hubDevice == null) {
      if (DateTime.now().isAfter(until) || !joined.den.hasFamily) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    final client = HubPushClient(network);
    try {
      final status = await client.status();
      final host = status.hostKey;
      if (host == null || status.subscribed) return;
      final browser = await WebApp.pushState(host);
      final subscription = browser.subscription;
      if (subscription == null || !browser.same) return;
      await client.subscribe(subscription, key: host);
    } on Object {
      // Settings shows where reminders stand, and turns them on with a tap.
    } finally {
      client.close();
    }
  }

  /// Gives a change this device just wrote [flush] to go out while the family's hub is
  /// connected.
  static Future<void> _sent(DenNetwork? network, Duration flush) async {
    if (network == null || !network.connecting) return;
    await Future<void>.delayed(flush);
  }
}
