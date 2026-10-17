import 'dart:io';

/// How much the hub says.
enum LogLevel {
  /// Every request and background step.
  debug,

  /// Starts, stops, joins, feed refreshes.
  info,

  /// Things that failed but the hub carries on.
  warn,

  /// Things that stop a part of the hub from working.
  error,
}

/// The hub's log. Lines never carry tokens, PINs, setup codes (except the one line that shows a
/// fresh hub's code, which is how that code proves access to the hub), invite secrets or the
/// contents of changes; callers pass only what is safe to show.
class HubLog {
  /// Writes lines at [level] and above to [sink] (default: standard error).
  HubLog({this.level = LogLevel.info, void Function(String line)? sink}) : _sink = sink ?? _stderr;

  /// The lowest level written.
  final LogLevel level;
  final void Function(String line) _sink;

  static void _stderr(String line) => stderr.writeln(line);

  /// A log that writes nothing.
  static HubLog silent() => HubLog(level: LogLevel.error, sink: (_) {});

  void _write(LogLevel at, String message) {
    if (at.index < level.index) return;
    final time = DateTime.now().toUtc().toIso8601String();
    _sink('$time ${at.name.toUpperCase().padRight(5)} $message');
  }

  /// Logs at debug level.
  void debug(String message) => _write(LogLevel.debug, message);

  /// Logs at info level.
  void info(String message) => _write(LogLevel.info, message);

  /// Logs at warn level.
  void warn(String message) => _write(LogLevel.warn, message);

  /// Logs at error level.
  void error(String message) => _write(LogLevel.error, message);
}

/// What an error was, without its message (which may hold data): its type and where it came
/// from.
String describeError(Object error, [StackTrace? stack]) {
  final frames = stack?.toString().split('\n').where((l) => l.contains('den_')).take(3).join(' | ');
  return frames == null || frames.isEmpty ? '${error.runtimeType}' : '${error.runtimeType} at $frames';
}
