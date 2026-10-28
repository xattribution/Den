/// JSON Schemas for actions, built in Dart.
///
/// Inputs stay in the portable subset every function-calling API takes (Anthropic, OpenAI,
/// Gemini, xAI, Ollama, and MCP clients): an object at the top, one type per value, string
/// enums, `items` on every array, properties on every nested object, no `anyOf`, and
/// `additionalProperties: false` only at the top. Outputs are plain JSON Schema for MCP's
/// `outputSchema`, where a value that may be missing is typed `["string", "null"]`.
library;

import 'resolve.dart';

/// Schema builders.
abstract final class S {
  static Object _type(String type, bool nullable) => nullable ? [type, 'null'] : type;

  /// Text, optionally one of [oneOf].
  static Map<String, Object?> string(
    String description, {
    List<String>? oneOf,
    int? minLength,
    int? maxLength,
    bool nullable = false,
  }) =>
      {
        'type': _type('string', nullable),
        'description': description,
        'enum': ?oneOf,
        'minLength': ?minLength,
        'maxLength': ?maxLength,
      };

  /// A whole number.
  static Map<String, Object?> integer(String description, {int? min, int? max, bool nullable = false}) => {
        'type': _type('integer', nullable),
        'description': description,
        'minimum': ?min,
        'maximum': ?max,
      };

  /// True or false.
  static Map<String, Object?> boolean(String description, {bool nullable = false}) =>
      {'type': _type('boolean', nullable), 'description': description};

  /// A list of [items].
  static Map<String, Object?> array(
    Map<String, Object?> items,
    String description, {
    int? minItems,
    int? maxItems,
    bool nullable = false,
  }) =>
      {
        'type': _type('array', nullable),
        'description': description,
        'items': items,
        'minItems': ?minItems,
        'maxItems': ?maxItems,
      };

  /// An object with [properties].
  static Map<String, Object?> object(
    Map<String, Object?> properties, {
    String? description,
    List<String> required = const [],
    bool nullable = false,
  }) =>
      {
        'type': _type('object', nullable),
        'description': ?description,
        'properties': properties,
        if (required.isNotEmpty) 'required': required,
      };

  /// An object whose keys are data (member ids, store names); outputs only.
  static Map<String, Object?> dictionary(String description) => {'type': 'object', 'description': description};

  /// Any JSON value; outputs only.
  static Map<String, Object?> any(String description) => {'description': description};

  /// An action's input: the top-level object, closed to keys it doesn't name.
  static Map<String, Object?> input(Map<String, Object?> properties, {List<String> required = const []}) => {
        'type': 'object',
        'properties': properties,
        if (required.isNotEmpty) 'required': required,
        'additionalProperties': false,
      };

  /// An action's output, for MCP's `outputSchema`.
  static Map<String, Object?> output(Map<String, Object?> properties, {List<String> required = const []}) => {
        'type': 'object',
        'properties': properties,
        if (required.isNotEmpty) 'required': required,
      };

  /// A time, as an action input takes one.
  static Map<String, Object?> time(String description) => string(
        '$description ISO 8601 with an offset (2026-10-20T15:00:00-05:00), without one (read in the '
        'family\'s time zone), or a date (2026-10-20).',
      );

  /// A local date.
  static Map<String, Object?> date(String description) =>
      string('$description A date like 2026-10-20, or today, tomorrow or yesterday.');

  /// A person.
  static Map<String, Object?> person(String description) =>
      string('$description A name or member id; "me" is the person this connection acts for.');

  /// Several people.
  static Map<String, Object?> people(String description) => array(string('A name or member id.'), description, maxItems: 50);
}

String _join(String path, String key) => path.isEmpty ? key : '$path.$key';

ActionError _bad(String path, String what) => ActionError('"$path" $what.', field: path);

Map<String, Object?> _map(Object? value) => value is Map ? value.cast<String, Object?>() : const {};

/// [args] checked against an action's [schema] and put in the shapes it names: a number where
/// text goes becomes text, `"5"` or `5.0` where a whole number goes becomes `5`, `"true"` where
/// a flag goes becomes `true`, one value where a list goes becomes a list of it, and an enum
/// value matches whatever its case. A null is kept as given (an input left out). Throws
/// [ActionError] naming the first problem: a missing or empty required value, the wrong type,
/// a value out of range or not in the enum, or a key the schema doesn't take.
Map<String, Object?> normalizeInput(Map<String, Object?> schema, Map<String, Object?> args) =>
    _normalize(schema, args, '') as Map<String, Object?>;

Object? _normalize(Map<String, Object?> schema, Object? value, String path) {
  if (value == null) return null;
  switch (schema['type']) {
    case 'object':
      if (value is! Map) throw path.isEmpty ? ActionError('The arguments must be an object.') : _bad(path, 'must be an object');
      final props = _map(schema['properties']);
      final out = <String, Object?>{};
      for (final e in value.entries) {
        final key = '${e.key}';
        final child = props[key];
        if (child is! Map) {
          if (schema['additionalProperties'] == false) {
            final where = path.isEmpty ? 'This' : '"$path"';
            final takes = props.isEmpty ? 'it takes nothing' : 'it takes ${props.keys.join(', ')}';
            throw ActionError('$where doesn\'t take "$key"; $takes.', field: _join(path, key));
          }
          out[key] = e.value;
          continue;
        }
        out[key] = _normalize(_map(child), e.value, _join(path, key));
      }
      for (final r in (schema['required'] as List?) ?? const []) {
        final v = out[r];
        if (v == null) throw _bad(_join(path, '$r'), 'is required');
        if (v is String && v.trim().isEmpty) throw _bad(_join(path, '$r'), 'can\'t be empty');
        if (v is List && v.isEmpty && ((_map(props[r])['minItems'] as int?) ?? 0) > 0) {
          throw _bad(_join(path, '$r'), 'needs at least one entry');
        }
      }
      return out;
    case 'array':
      final list = value is List ? value : [value];
      final max = schema['maxItems'];
      final min = schema['minItems'];
      if (max is int && list.length > max) throw _bad(path, 'has too many entries ($max at most)');
      if (min is int && list.length < min) throw _bad(path, 'needs at least $min');
      final items = _map(schema['items']);
      return [for (var i = 0; i < list.length; i++) _normalize(items, list[i], '$path[$i]')];
    case 'string':
      final String text;
      if (value is String) {
        text = value;
      } else if (value is num || value is bool) {
        text = '$value';
      } else {
        throw _bad(path, 'must be text');
      }
      final oneOf = schema['enum'];
      if (oneOf is List) {
        final t = text.trim().toLowerCase();
        for (final option in oneOf) {
          if ('$option'.toLowerCase() == t) return option;
        }
        throw _bad(path, 'must be one of ${oneOf.join(', ')}');
      }
      final max = schema['maxLength'];
      if (max is int && text.length > max) throw _bad(path, 'is too long ($max characters at most)');
      final min = schema['minLength'];
      if (min is int && text.trim().length < min) throw _bad(path, min <= 1 ? 'can\'t be empty' : 'is too short');
      return text;
    case 'integer':
      final n = value is int
          ? value
          : value is double && value == value.roundToDouble()
              ? value.toInt()
              : value is String
                  ? int.tryParse(value.trim())
                  : null;
      if (n == null) throw _bad(path, 'must be a whole number');
      final min = schema['minimum'];
      final max = schema['maximum'];
      if (min is int && n < min) throw _bad(path, 'must be at least $min');
      if (max is int && n > max) throw _bad(path, 'must be at most $max');
      return n;
    case 'boolean':
      if (value is bool) return value;
      if (value is String && value.trim().toLowerCase() == 'true') return true;
      if (value is String && value.trim().toLowerCase() == 'false') return false;
      throw _bad(path, 'must be true or false');
    default:
      return value;
  }
}

/// Where [value] strays from [schema] (types, required keys, enums, items, and keys a closed
/// object doesn't name), as `path: problem` lines; empty when it fits. For checking outputs.
List<String> schemaProblems(Map<String, Object?> schema, Object? value, [String path = r'$']) {
  final out = <String>[];
  _check(schema, value, path, out);
  return out;
}

bool _isType(String type, Object? value) => switch (type) {
      'null' => value == null,
      'string' => value is String,
      'integer' => value is int,
      'number' => value is num,
      'boolean' => value is bool,
      'array' => value is List,
      'object' => value is Map,
      _ => true,
    };

void _check(Map<String, Object?> schema, Object? value, String path, List<String> out) {
  final type = schema['type'];
  final types = type is List ? [for (final t in type) '$t'] : type is String ? [type] : const <String>[];
  if (types.isNotEmpty && !types.any((t) => _isType(t, value))) {
    out.add('$path: expected ${types.join(' or ')}, got ${value == null ? 'null' : value.runtimeType}');
    return;
  }
  final oneOf = schema['enum'];
  if (oneOf is List && value != null && !oneOf.contains(value)) out.add('$path: $value is not one of ${oneOf.join(', ')}');
  if (value is Map) {
    final props = _map(schema['properties']);
    for (final r in (schema['required'] as List?) ?? const []) {
      if (!value.containsKey(r)) out.add('$path: missing "$r"');
    }
    for (final e in value.entries) {
      final child = props['${e.key}'];
      if (child is Map) {
        _check(_map(child), e.value, '$path.${e.key}', out);
      } else if (schema['additionalProperties'] == false) {
        out.add('$path: unexpected "${e.key}"');
      }
    }
  } else if (value is List) {
    final items = schema['items'];
    if (items is Map) {
      for (var i = 0; i < value.length; i++) {
        _check(_map(items), value[i], '$path[$i]', out);
      }
    }
  }
}
