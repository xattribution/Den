import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import 'hub_client.dart';

export 'hub_client.dart' show FoundHub, HubInfo;

/// Where a join attempt stands, as the joining device sees it.
enum JoinState { waiting, approved, declined, failed }

class JoinStatus {
  const JoinStatus(this.state, {this.message});

  final JoinState state;

  /// Written for people: why it was declined or failed, and what to do next.
  final String? message;
}

/// A join request this device has sent: the family it reached and the three matching words both
/// screens show (derived from the session transcript; empty for QR joins, where the code itself
/// carries the inviter's key).
class JoinTicket {
  const JoinTicket({required this.familyId, this.familyName, this.inviterName, this.words = const []});

  final String familyId;
  final String? familyName;

  /// The inviting device's name, such as "Mia's phone", when the session reveals it.
  final String? inviterName;
  final List<String> words;
}

/// A 4-word code a parent reads out to a device that can't scan, valid until [expires].
class SpokenCode {
  const SpokenCode({required this.words, required this.expires});

  final List<String> words;

  /// UTC milliseconds.
  final int expires;
}

/// A device asking to join, as the inviting device sees it, with the matching words to compare.
class PendingJoin {
  const PendingJoin({required this.deviceId, required this.deviceName, required this.kind, this.words = const []});

  final String deviceId;
  final String deviceName;
  final DeviceKind kind;
  final List<String> words;
}

/// A failure written for people: the cause and the way out.
class PairingException implements Exception {
  const PairingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Adding devices to the family: QR invites, spoken codes and matching words. The app talks to
/// this; den_net implements it. Joining writes this device's own unapproved device record (via
/// [Den.requestJoin]); a parent's device then approves it with [Den.approveDevice].
abstract class PairingService {
  const PairingService();

  /// Joins with a scanned `den://join?...` URI. [deviceName] and [kind] describe this device in
  /// its join request.
  Future<JoinTicket> joinWithQr(String uri, {required String deviceName, required DeviceKind kind});

  /// Joins with the 4 spoken words. [hubUrl] reaches a hub directly when the relay isn't used.
  Future<JoinTicket> joinWithCode(
    String words, {
    String? hubUrl,
    required String deviceName,
    required DeviceKind kind,
  });

  /// The joining device's progress: waiting, then approved, declined or failed (with a message).
  Stream<JoinStatus> get joinStatus;

  /// A fresh invite as a `den://join` URI, to show as a QR code.
  Future<String> createInviteQr();

  /// A fresh 4-word code with its expiry.
  Future<SpokenCode> createSpokenCode();

  /// Devices waiting for this device's parent to compare words and approve.
  Stream<List<PendingJoin>> get pendingJoins;

  // ------------------------------------------------------------------ hubs

  /// Hubs answering mDNS on the home network (none in a browser).
  Future<List<FoundHub>> findHubs() async => const [];

  /// What the hub at [address] ("192.168.1.20", "den-hub.local:47733") says about itself.
  Future<HubInfo> hubStatus(String address) async => throw const PairingException(LocalOnlyPairing.message);

  /// Adds a fresh hub to the family with the 8-character setup code it printed: sends an invite
  /// and the code, serves the hub's join, and waits for a parent to approve it as the hub.
  HubSetupSession setUpHub(HubInfo hub, String code) => throw const PairingException(LocalOnlyPairing.message);

  /// Saves a hub already in this family as the place to sync.
  Future<void> useHub(HubInfo hub) async {}

  // ------------------------------------------------------------------ browsers

  /// In a browser the hub served: asks it for a link code to show as a QR code, then joins with
  /// the invite a parent's phone leaves for it. [deviceName] is read when the invite arrives.
  Future<BrowserLinkSession> linkThisBrowser({required String Function() deviceName}) async =>
      throw const PairingException(LocalOnlyPairing.message);

  /// On a parent's phone: answers a browser's `den://link` code with an invite the hub accepts
  /// on this phone's behalf. Returns the hub's name; the browser's join request then arrives as a
  /// pending device to approve.
  Future<String> answerBrowserLink(String code) async => throw const PairingException(LocalOnlyPairing.message);
}

/// Where adding a hub stands, on the parent's phone.
enum HubSetupStage {
  /// Sending the setup code and an invite.
  sending,

  /// Waiting for the hub to reach this phone and ask to join.
  waiting,

  /// The hub asked; compare the words and approve it.
  confirm,

  /// Approved; the hub is catching up with the family.
  approving,

  /// The hub is in the family and saved as the place to sync.
  done,

  /// Something went wrong; [HubSetupSession.error] says what and what to do.
  failed,
}

/// One run of adding a hub: follow [stage], show [words], then [approve] or [cancel].
abstract class HubSetupSession extends ChangeNotifier {
  HubInfo get hub;
  HubSetupStage get stage;
  String? get error;

  /// The three matching words, once the hub has asked to join.
  List<String> get words;

  Future<void> approve();
  Future<void> cancel();
}

/// Where linking this browser stands.
enum LinkStage {
  /// Showing the code; waiting for a parent's phone to scan it.
  waiting,

  /// The phone answered; this browser is asking to join.
  joining,

  /// The join request is sent; [BrowserLinkSession.ticket] has the words.
  joined,

  /// The code ran out before anyone scanned it.
  expired,

  /// Something went wrong; [BrowserLinkSession.error] says what and what to do.
  failed,
}

/// A browser's link code at its hub, while it waits for a parent's phone.
abstract class BrowserLinkSession extends ChangeNotifier {
  /// The `den://link` URI to show as a QR code.
  String get uri;

  /// The hub that served this page.
  Uri get hub;

  /// UTC milliseconds when the code stops working.
  int get expires;

  LinkStage get stage;
  String? get error;

  /// The join this browser sent, once [stage] is [LinkStage.joined].
  JoinTicket? get ticket;

  Future<void> cancel();
}

/// Used until the hub or relay is wired in: every network step fails with a plain message.
class LocalOnlyPairing extends PairingService {
  const LocalOnlyPairing();

  static const message = "Connecting devices needs the hub or relay, which isn't set up yet.";

  @override
  Future<JoinTicket> joinWithQr(String uri, {required String deviceName, required DeviceKind kind}) async =>
      throw const PairingException(message);

  @override
  Future<JoinTicket> joinWithCode(
    String words, {
    String? hubUrl,
    required String deviceName,
    required DeviceKind kind,
  }) async =>
      throw const PairingException(message);

  @override
  Stream<JoinStatus> get joinStatus => const Stream.empty();

  @override
  Future<String> createInviteQr() async => throw const PairingException(message);

  @override
  Future<SpokenCode> createSpokenCode() async => throw const PairingException(message);

  @override
  Stream<List<PendingJoin>> get pendingJoins => Stream.value(const []);
}

/// The app's pairing service. Startup code replaces [service] with den_net's implementation;
/// tests can override it below a widget with [PairingScope].
abstract final class Pairing {
  static PairingService service = const LocalOnlyPairing();

  /// The join this device sent most recently, so the waiting screen can show its words.
  static JoinTicket? ticket;

  static PairingService of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PairingScope>()?.service ?? service;
}

class PairingScope extends InheritedWidget {
  const PairingScope({super.key, required this.service, required super.child});
  final PairingService service;

  @override
  bool updateShouldNotify(PairingScope oldWidget) => oldWidget.service != service;
}
