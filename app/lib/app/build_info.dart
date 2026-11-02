import 'dart:convert';

/// Which build of Den this is: the commit it was built from and when, set when it's built
/// (`--dart-define=DEN_COMMIT=<short commit> --dart-define=DEN_BUILT=<UTC time>`, which the hub's
/// Dockerfile and tool/local_ci.sh pass). Settings → About shows it, so someone can say which
/// build they're on.
abstract final class DenBuild {
  /// The short commit, or empty for a build that wasn't given one.
  static const String commit = String.fromEnvironment('DEN_COMMIT');

  /// When it was built, as ISO 8601 in UTC (`2026-10-29T17:10Z`), or empty.
  static const String built = String.fromEnvironment('DEN_BUILT');

  /// "abc1234, built 2026-10-29 17:10 UTC"; "Built on this computer" for a build given neither.
  static String get label => describe(commit, built);

  /// [commit] and [built] as [label] says them.
  static String describe(String commit, String built) {
    final when = _when(built);
    if (commit.isEmpty && when == null) return 'Built on this computer';
    if (commit.isEmpty) return 'Built $when';
    if (when == null) return commit;
    return '$commit, built $when';
  }

  static String? _when(String built) {
    final at = DateTime.tryParse(built);
    if (at == null) return built.isEmpty ? null : built;
    final utc = at.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year}-${two(utc.month)}-${two(utc.day)} ${two(utc.hour)}:${two(utc.minute)} UTC';
  }
}

/// What the hub says it serves now: its `build.json` (the web app's commit and build time, which
/// the hub's Dockerfile writes) and the version its `/health` reports.
class HubBuild {
  const HubBuild({this.commit = '', this.built = '', this.version});

  /// Reads `build.json` and `/health`'s text; null when neither says anything.
  static HubBuild? parse({String? build, String? health}) {
    Map<String, Object?>? read(String? text) {
      if (text == null) return null;
      try {
        final json = jsonDecode(text);
        return json is Map ? Map<String, Object?>.from(json) : null;
      } on FormatException {
        return null;
      }
    }

    final b = read(build), h = read(health);
    final commit = b?['commit'] is String ? b!['commit'] as String : '';
    final built = b?['built'] is String ? b!['built'] as String : '';
    final version = h?['version'] is String ? h!['version'] as String : null;
    if (commit.isEmpty && built.isEmpty && version == null) return null;
    return HubBuild(commit: commit, built: built, version: version);
  }

  final String commit;
  final String built;
  final String? version;

  /// "abc1234, built 2026-10-29 17:10 UTC · hub 0.1.0".
  String get label {
    final parts = [
      if (commit.isNotEmpty || built.isNotEmpty) DenBuild.describe(commit, built),
      if (version != null) 'hub $version',
    ];
    return parts.join(' · ');
  }

  /// The hub serves another build than [commit] (this app's): a newer one waits to be opened.
  bool differsFrom(String commit) => this.commit.isNotEmpty && commit.isNotEmpty && this.commit != commit;
}
