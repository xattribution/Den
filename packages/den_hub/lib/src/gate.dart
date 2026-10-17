import 'dart:async';

import 'package:den_core/den_core.dart';

/// Serializes everything the hub does through its [Den] on someone's behalf. A hub acts for one
/// caller at a time ([Den.actAs] is engine-wide), so each call sets who is acting, runs, and
/// resets before the next one starts.
class DenGate {
  /// Creates a gate over [den].
  DenGate(this.den);

  /// The hub's engine.
  final Den den;
  Future<void> _tail = Future.value();

  /// Runs [body] with [member] acting (null: the hub itself, at parent level) and [via]
  /// recorded on every change it writes.
  Future<T> run<T>(String? member, String? via, FutureOr<T> Function() body) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        if (member != null || via != null) den.actAs(member, via: via, window: const Duration(minutes: 10));
        result.complete(await body());
      } catch (e, s) {
        result.completeError(e, s);
      } finally {
        if (member != null || via != null) {
          try {
            den.actAs(null);
          } on Object {
            // The engine closed underneath; nothing is acting anymore.
          }
        }
      }
    });
    return result.future;
  }

  /// Runs [body] as the hub itself, with nobody acting.
  Future<T> asHub<T>(FutureOr<T> Function() body, {String? via}) => run(null, via, body);
}
