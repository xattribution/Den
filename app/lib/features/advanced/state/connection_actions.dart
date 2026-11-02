import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/den_scope.dart';

/// Which assistants and automations may reach the family, and as whom. Trust decisions: no
/// action offers them (an assistant can't approve itself or widen its own access), so they go
/// to the engine directly, from a parent's own device.
class ConnectionActions {
  const ConnectionActions(this._den);

  final Den _den;

  /// Approves [connection] with [scopes], acting as [member] (the parent approving, unless they
  /// chose someone), whose time zone is [tz] (null: the family's).
  Future<void> approve(String connection, {required Set<Scope> scopes, required String member, String? tz}) =>
      _den.approveConnection(connection, scopes: scopes, member: member, tz: tz);

  /// Changes who [connection] acts as, or the time zone its person lives in (null: the family's).
  Future<void> update(String connection, {required String member, String? tz}) =>
      _den.updateConnection(connection, member: member, tz: tz ?? '');

  /// Declines a request or revokes a connection; its token stops working at once.
  Future<void> revoke(String connection) => _den.revokeConnection(connection);

  /// Makes a token for a script or an assistant that can't sign in; the token is shown once.
  Future<String> addToken({required String label, required Set<Scope> scopes, required String member, String? tz}) =>
      _den.addTokenConnection(label: label, scopes: scopes, member: member, tz: tz);
}

extension ConnectionActionsOf on BuildContext {
  ConnectionActions get connectionActions => ConnectionActions(actions.den);
}
