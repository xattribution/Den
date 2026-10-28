import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/den_scope.dart';

/// Which assistants and automations may reach the family, and as whom. Trust decisions: no
/// action offers them (an assistant can't approve itself or widen its own access), so they go
/// to the engine directly, from a parent's own device.
class ConnectionActions {
  const ConnectionActions(this._den);

  final Den _den;

  Future<void> approve(String connection, {required Set<Scope> scopes, String? member}) =>
      _den.approveConnection(connection, scopes: scopes, member: member);

  /// Declines a request or revokes a connection; its token stops working at once.
  Future<void> revoke(String connection) => _den.revokeConnection(connection);

  /// Makes a token for a script or an assistant that can't sign in; the token is shown once.
  Future<String> addToken({required String label, required Set<Scope> scopes, String? member}) =>
      _den.addTokenConnection(label: label, scopes: scopes, member: member);
}

extension ConnectionActionsOf on BuildContext {
  ConnectionActions get connectionActions => ConnectionActions(actions.den);
}
