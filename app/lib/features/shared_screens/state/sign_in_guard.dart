import 'dart:convert';
import 'dart:math' as math;

/// Wrong PINs and picture patterns on this device, per person: after a wrong one, the next try
/// for that person waits [wait], so trying every 4-digit PIN at a shared screen would take more
/// than two days of standing there. A right one clears the count. Kept on the device
/// ([toJson]), so restarting Den neither skips the wait nor resets the count the parents hear
/// about ([tell]).
///
/// A clock set back never makes the wait longer than [wait]; the engine only checks a secret
/// (`Den.verifySignIn`), and the waiting is the screen's.
class SignInGuard {
  SignInGuard({required int Function() now, Map<String, (int, int)> tries = const {}, this.onChange})
      : _now = now,
        _tries = {...tries};

  /// Reads what [toJson] wrote; anything it can't read starts over.
  factory SignInGuard.fromJson(String? json, {required int Function() now, void Function(String json)? onChange}) {
    final tries = <String, (int, int)>{};
    try {
      final raw = json == null ? null : jsonDecode(json);
      if (raw is Map) {
        for (final e in raw.entries) {
          final v = e.value;
          if (e.key is String && v is List && v.length == 2 && v[0] is int && v[1] is int) {
            tries[e.key as String] = (v[0] as int, v[1] as int);
          }
        }
      }
    } on FormatException {
      // Nothing kept.
    }
    return SignInGuard(now: now, tries: tries, onChange: onChange);
  }

  /// How long the next try waits after a wrong one. The same every time: no lockout.
  static const Duration wait = Duration(seconds: 20);

  /// Every this many wrong tries in a row, a shared screen tells the parents
  /// (`Den.noteSignInTries`).
  static const int tell = 10;

  final int Function() _now;

  /// Member id to (wrong tries in a row, when the last one was).
  final Map<String, (int, int)> _tries;

  /// Called with [toJson] after every change, to keep it.
  final void Function(String json)? onChange;

  /// [member]'s wrong tries in a row on this device.
  int wrong(String member) => _tries[member]?.$1 ?? 0;

  /// How long [member] waits before the next try; zero when they may try now.
  Duration left(String member) {
    final last = _tries[member]?.$2;
    if (last == null) return Duration.zero;
    final since = math.max(0, _now() - last);
    return since >= wait.inMilliseconds ? Duration.zero : Duration(milliseconds: wait.inMilliseconds - since);
  }

  /// Counts a wrong try for [member]; returns how many in a row now.
  int failed(String member) {
    final wrong = this.wrong(member) + 1;
    _tries[member] = (wrong, _now());
    _changed();
    return wrong;
  }

  /// A right one: [member] starts over.
  void succeeded(String member) {
    if (_tries.remove(member) != null) _changed();
  }

  String toJson() => jsonEncode({for (final e in _tries.entries) e.key: [e.value.$1, e.value.$2]});

  void _changed() => onChange?.call(toJson());
}

/// "Try again in 20 seconds", rounded up, said plainly.
String tryAgainIn(Duration left) {
  final seconds = math.max(1, (left.inMilliseconds / 1000).ceil());
  return 'Try again in $seconds ${seconds == 1 ? 'second' : 'seconds'}';
}
