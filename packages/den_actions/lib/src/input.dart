import 'resolve.dart';

/// An action's arguments after [normalizeInput] checked them against its schema: typed reads
/// that can trust the shapes, and still explain anything a schema can't say.
class ActionInput {
  /// Wraps checked arguments.
  ActionInput(this.raw);

  /// The arguments.
  final Map<String, Object?> raw;

  /// Whether [key] was given, not null.
  bool has(String key) => raw[key] != null;

  /// Whether [key] was given at all, even as null.
  bool present(String key) => raw.containsKey(key);

  /// A text argument; [required] refuses an empty one.
  String? str(String key, {bool required = false}) {
    final v = raw[key];
    if (v == null) {
      if (required) throw ActionError('"$key" is required.', field: key);
      return null;
    }
    final s = '$v';
    if (required && s.trim().isEmpty) throw ActionError('"$key" can\'t be empty.', field: key);
    return s;
  }

  /// A whole-number argument.
  int? integer(String key, {bool required = false}) {
    final v = raw[key];
    if (v == null) {
      if (required) throw ActionError('"$key" is required.', field: key);
      return null;
    }
    if (v is int) return v;
    throw ActionError('"$key" must be a whole number.', field: key);
  }

  /// A true-or-false argument.
  bool? flag(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is bool) return v;
    throw ActionError('"$key" must be true or false.', field: key);
  }

  /// A list argument.
  List<Object?>? list(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is List) return v;
    throw ActionError('"$key" must be a list.', field: key);
  }

  /// A list of objects argument.
  List<Map<String, Object?>>? objects(String key) {
    final l = list(key);
    if (l == null) return null;
    return [
      for (final v in l)
        if (v is Map) v.cast<String, Object?>() else throw ActionError('Each entry of "$key" must be an object.', field: key),
    ];
  }

  /// Integers of a list argument.
  List<int>? ints(String key) {
    final l = list(key);
    return l == null ? null : [for (final v in l) if (v is int) v];
  }
}
