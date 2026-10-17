import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

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
