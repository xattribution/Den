import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/den_scope.dart';

/// Who is acting on this shared screen. Device-local: nothing here changes the family, so no
/// action offers it.
class SignInActions {
  const SignInActions(this._den);

  final Den _den;

  /// Whether [secret] (a PIN or a picture pattern) is [member]'s.
  Future<bool> verify(String member, String secret) => _den.verifySignIn(member, secret);

  /// Lets [member] act on this screen for [window]. Throws [PermissionDenied] when they can't.
  void actAs(String member, {Duration window = const Duration(seconds: 60)}) => _den.actAs(member, window: window);

  /// Back to nobody acting.
  void signOut() => _den.actAs(null);
}

extension SignInActionsOf on BuildContext {
  SignInActions get signInActions => SignInActions(actions.den);
}
