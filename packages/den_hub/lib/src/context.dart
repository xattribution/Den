import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http_client;

import 'config.dart';
import 'gate.dart';
import 'log.dart';
import 'state.dart';

/// What every part of the hub shares.
class HubContext {
  /// Creates the shared context.
  HubContext({
    required this.den,
    required this.gate,
    required this.config,
    required this.log,
    required this.state,
    required this.node,
    required this.http,
  });

  /// The hub's engine.
  final Den den;

  /// Serializes acting on [den].
  final DenGate gate;

  /// How the hub runs.
  final HubConfig config;

  /// Where the hub logs.
  final HubLog log;

  /// The hub's own small state.
  final HubState state;

  /// Sync for [den].
  final SyncNode node;

  /// Outgoing HTTP (feeds, notifiers).
  final http_client.Client http;

  /// In a family, approved, log loaded: the API answers.
  bool get ready => den.hasFamily && den.isApproved;

  /// The hub device's name.
  String get name => den.thisDevice?.name ?? config.name;

  /// The family's time zone.
  String get zone => den.family?.timezone ?? 'UTC';

  /// UTC milliseconds now.
  int now() => DateTime.now().toUtc().millisecondsSinceEpoch;
}
