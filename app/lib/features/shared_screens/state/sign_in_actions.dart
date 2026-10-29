import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/den_scope.dart';
import 'sign_in_guard.dart';

/// What checking a PIN or picture pattern came to: right, or not, and how long the next try
/// waits ([wait] is zero when they may try again now). While someone waits, nothing is checked.
class SignInCheck {
  const SignInCheck.right()
      : ok = true,
        wait = Duration.zero;
  const SignInCheck.wrong({this.wait = Duration.zero}) : ok = false;

  final bool ok;
  final Duration wait;
}

/// Who is acting on this shared screen. Device-local: nothing here changes the family, so no
/// action offers it. Wrong PINs and patterns count against the person on this device
/// ([SignInGuard]), and at every tenth in a row a shared screen tells the parents.
class SignInActions {
  const SignInActions(this._den, [this._guard]);

  final Den _den;
  final SignInGuard? _guard;

  /// How long [member] waits before the next try here; zero when they may try now.
  Duration waitFor(String member) => _guard?.left(member) ?? Duration.zero;

  /// Checks [secret] (a PIN or a picture pattern) against [member]'s, unless wrong tries make
  /// them wait.
  Future<SignInCheck> verify(String member, String secret) async {
    final guard = _guard;
    final wait = waitFor(member);
    if (wait > Duration.zero) return SignInCheck.wrong(wait: wait);
    final ok = await _den.verifySignIn(member, secret);
    final kind = _den.member(member)?.signIn.kind;
    // Only a PIN or a pattern can be guessed; someone with neither has nothing to try.
    if (guard == null || (kind != 'pin' && kind != 'pattern')) {
      return ok ? const SignInCheck.right() : const SignInCheck.wrong();
    }
    if (ok) {
      guard.succeeded(member);
      return const SignInCheck.right();
    }
    final wrong = guard.failed(member);
    if (wrong % SignInGuard.tell == 0 && _den.thisDevice?.mode == DeviceMode.shared) {
      unawaited(_den.noteSignInTries(member, wrong).catchError((Object _) {}));
    }
    return SignInCheck.wrong(wait: guard.left(member));
  }

  /// Lets [member] act on this screen for [window]. Throws [PermissionDenied] when they can't.
  void actAs(String member, {Duration window = const Duration(seconds: 60)}) => _den.actAs(member, window: window);

  /// Back to nobody acting.
  void signOut() => _den.actAs(null);
}

extension SignInActionsOf on BuildContext {
  SignInActions get signInActions {
    final app = DenScope.read(this);
    return SignInActions(app.den, app.signInGuard);
  }
}
