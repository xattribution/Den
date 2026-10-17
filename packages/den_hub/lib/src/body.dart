import 'http_util.dart';

/// Typed, validated access to a JSON request body; every problem is `400 invalid_input` naming
/// the field.
class Body {
  /// Wraps a decoded JSON object.
  Body(this.json);

  /// The decoded body.
  final Map<String, Object?> json;

  /// Whether the body has [key] (even with a null value).
  bool has(String key) => json.containsKey(key);

  /// The raw value.
  Object? operator [](String key) => json[key];

  ApiError _bad(String key, String what) => ApiError.invalid('"$key" $what.', field: key);

  /// A string of [min] to [max] characters (trimmed for the length check).
  String? string(String key, {bool required = false, int min = 0, int max = 200, bool nullable = false}) {
    if (!has(key)) {
      if (required) throw _bad(key, 'is required');
      return null;
    }
    final v = json[key];
    if (v == null) {
      if (nullable && !required) return null;
      throw _bad(key, required ? 'is required' : 'can\'t be null');
    }
    if (v is! String) throw _bad(key, 'must be text');
    if (v.trim().length < min) throw _bad(key, min <= 1 ? 'can\'t be empty' : 'is too short');
    if (v.length > max) throw _bad(key, 'is too long ($max characters at most)');
    return v;
  }

  /// A bool.
  bool? flag(String key, {bool? fallback}) {
    final v = json[key];
    if (v == null) {
      if (has(key)) throw _bad(key, 'must be true or false');
      return fallback;
    }
    if (v is! bool) throw _bad(key, 'must be true or false');
    return v;
  }

  /// An integer in [min, max].
  int? integer(String key, {bool required = false, int? min, int? max}) {
    final v = json[key];
    if (v == null) {
      if (required) throw _bad(key, 'is required');
      if (has(key)) throw _bad(key, 'must be a whole number');
      return null;
    }
    final n = v is int ? v : (v is double && v == v.roundToDouble() ? v.toInt() : null);
    if (n == null) throw _bad(key, 'must be a whole number');
    if (min != null && n < min) throw _bad(key, 'must be at least $min');
    if (max != null && n > max) throw _bad(key, 'must be at most $max');
    return n;
  }

  /// A list of strings.
  List<String>? strings(String key, {int max = 50}) {
    final v = json[key];
    if (v == null) {
      if (has(key)) throw _bad(key, 'must be a list');
      return null;
    }
    if (v is! List || v.any((e) => e is! String)) throw _bad(key, 'must be a list of text');
    if (v.length > max) throw _bad(key, 'has too many entries ($max at most)');
    return v.cast<String>();
  }

  /// A list of integers in [min, max].
  List<int>? ints(String key, {int max = 10, int? min, int? maxValue}) {
    final v = json[key];
    if (v == null) {
      if (has(key)) throw _bad(key, 'must be a list');
      return null;
    }
    if (v is! List || v.any((e) => e is! int)) throw _bad(key, 'must be a list of whole numbers');
    if (v.length > max) throw _bad(key, 'has too many entries ($max at most)');
    for (final n in v.cast<int>()) {
      if ((min != null && n < min) || (maxValue != null && n > maxValue)) {
        throw _bad(key, 'entries must be from ${min ?? 0} to ${maxValue ?? n}');
      }
    }
    return v.cast<int>();
  }

  /// A JSON object.
  Map<String, Object?>? object(String key) {
    final v = json[key];
    if (v == null) return null;
    if (v is! Map) throw _bad(key, 'must be an object');
    return v.cast<String, Object?>();
  }
}
