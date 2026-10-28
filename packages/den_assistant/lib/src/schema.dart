import 'json.dart';
import 'tools.dart';

/// The JSON Schema keywords all five providers accept in a tool's input, Gemini's
/// OpenAPI-style `parameters` being the narrowest. Ollama drops the size limits but takes them.
const portableKeywords = {
  'type',
  'description',
  'title',
  'properties',
  'required',
  'items',
  'enum',
  'minimum',
  'maximum',
  'minItems',
  'maxItems',
  'minLength',
  'maxLength',
};

/// The types a portable schema may use, one per value.
const portableTypes = {'object', 'string', 'integer', 'number', 'boolean', 'array'};

/// Tool and property names every provider takes: Gemini's rule for parameter names, which also
/// fits OpenAI's 64-character limit on function names.
final RegExp portableName = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,63}$');

/// Something in a tool's schema that some provider won't take.
class SchemaIssue {
  /// [message] about the keyword at [path] (`properties.items.items.anyOf`).
  const SchemaIssue(this.path, this.message);

  /// Where, as dotted keys; empty for the top.
  final String path;

  /// What's wrong.
  final String message;

  @override
  String toString() => path.isEmpty ? message : '$path: $message';
}

/// Checks [tool]'s name and input schema against the portable subset.
List<SchemaIssue> checkTool(AssistantTool tool) => [
      if (!portableName.hasMatch(tool.name))
        SchemaIssue('name', 'The tool name "${tool.name}" must be letters, digits and underscores, starting with a letter, at most 64.'),
      if (tool.description.trim().isEmpty) const SchemaIssue('description', 'Describe what the tool does.'),
      ...checkPortableSchema(tool.input),
    ];

/// The ways [schema] strays from the portable subset: an object at the top, one type per value,
/// string enums only, `items` on every array, properties on every nested object, and
/// `additionalProperties` (false) only at the top. Empty when every provider will take it.
List<SchemaIssue> checkPortableSchema(Map<String, Object?> schema) {
  final issues = <SchemaIssue>[];
  if (schema['type'] != 'object') {
    issues.add(const SchemaIssue('type', 'The input must be an object ("type": "object").'));
  }
  _check(schema, '', issues, root: true);
  return issues;
}

void _check(Map<String, Object?> schema, String path, List<SchemaIssue> issues, {bool root = false}) {
  String at(String key) => path.isEmpty ? key : '$path.$key';
  for (final key in schema.keys) {
    if (key == 'additionalProperties') {
      if (!root) {
        issues.add(SchemaIssue(at(key), 'Only the top level may set additionalProperties.'));
      } else if (schema[key] != false) {
        issues.add(SchemaIssue(at(key), 'additionalProperties may only be false.'));
      }
    } else if (!portableKeywords.contains(key)) {
      issues.add(SchemaIssue(at(key), '"$key" isn\'t in the portable subset.'));
    }
  }
  final type = schema['type'];
  if (type is! String || !portableTypes.contains(type)) {
    if (!root) issues.add(SchemaIssue(at('type'), 'Give one type: object, string, integer, number, boolean or array.'));
    return;
  }
  if (schema.containsKey('enum')) {
    final values = schema['enum'];
    if (type != 'string') {
      issues.add(SchemaIssue(at('enum'), 'Only strings may have an enum.'));
    } else if (values is! List || values.isEmpty || values.any((v) => v is! String)) {
      issues.add(SchemaIssue(at('enum'), 'An enum must be a list of strings.'));
    }
  }
  switch (type) {
    case 'object':
      final properties = schema['properties'];
      if (properties != null && properties is! Map) {
        issues.add(SchemaIssue(at('properties'), 'properties must be an object.'));
      }
      final props = asMap(properties);
      if (!root && props.isEmpty) {
        issues.add(SchemaIssue(at('properties'), 'A nested object needs properties; Gemini rejects empty ones.'));
      }
      for (final entry in props.entries) {
        final where = at('properties.${entry.key}');
        if (!portableName.hasMatch(entry.key)) {
          issues.add(SchemaIssue(where, 'Property names must be letters, digits and underscores, starting with a letter.'));
        }
        final child = entry.value;
        if (child is Map) {
          _check(asMap(child), where, issues);
        } else {
          issues.add(SchemaIssue(where, 'Each property needs a schema.'));
        }
      }
      final required = schema['required'];
      if (required != null) {
        if (required is! List) {
          issues.add(SchemaIssue(at('required'), 'required must be a list of property names.'));
        } else {
          for (final Object? name in required) {
            if (name is! String || !props.containsKey(name)) {
              issues.add(SchemaIssue(at('required'), '"$name" is required but isn\'t a property.'));
            }
          }
        }
      }
    case 'array':
      final items = schema['items'];
      if (items is Map) {
        _check(asMap(items), at('items'), issues);
      } else {
        issues.add(SchemaIssue(at('items'), 'An array needs one "items" schema.'));
      }
  }
}

/// [schema] for Anthropic's `input_schema`, OpenAI's and xAI's `parameters`, and Ollama: the
/// portable subset as it is, with an object at the top.
Map<String, Object?> jsonSchemaFor(Map<String, Object?> schema) => {
      ...schema,
      'type': 'object',
      'properties': schema['properties'] ?? <String, Object?>{},
    };

/// [schema] as Gemini's OpenAPI-style `parameters`: upper-case types, `nullable` for a
/// `["x", "null"]` type, string enums with `format: enum`, and anything it doesn't take left
/// out. Null for a tool without inputs, which Gemini wants declared without `parameters`.
Map<String, Object?>? geminiSchemaFor(Map<String, Object?> schema) {
  if (asMap(schema['properties']).isEmpty) return null;
  return _gemini({...schema, 'type': 'object'});
}

Map<String, Object?> _gemini(Map<String, Object?> schema) {
  final out = <String, Object?>{};
  for (final entry in schema.entries) {
    final value = entry.value;
    switch (entry.key) {
      case 'type':
        if (value is String) {
          out['type'] = value.toUpperCase();
        } else if (value is List) {
          final kinds = [for (final k in value) if (k is String && k != 'null') k];
          if (kinds.isNotEmpty) out['type'] = kinds.first.toUpperCase();
          if (value.contains('null')) out['nullable'] = true;
        }
      case 'properties':
        out['properties'] = {for (final p in asMap(value).entries) p.key: _gemini(asMap(p.value))};
      case 'items':
        out['items'] = _gemini(asMap(value));
      case 'enum':
        out['enum'] = [for (final v in asList(value)) '$v'];
        out['format'] = 'enum';
      case 'description' || 'title' || 'required' || 'nullable' || 'minimum' || 'maximum' || 'minItems' || 'maxItems' ||
            'minLength' || 'maxLength':
        out[entry.key] = value;
    }
  }
  return out;
}

/// What's wrong with [input] for a tool whose input schema is [schema]: missing required
/// values, wrong types, values outside an enum, and unknown keys when the schema closes them.
/// Empty when it fits. Each problem is a sentence the model can act on.
List<String> checkInput(Map<String, Object?> schema, Map<String, Object?> input) {
  final problems = <String>[];
  _checkValue(schema, input, '', problems);
  return problems;
}

String _joinPath(String path, String key) => path.isEmpty ? key : '$path.$key';

void _checkValue(Map<String, Object?> schema, Object? value, String path, List<String> problems) {
  final name = path.isEmpty ? 'The input' : '"$path"';
  switch (schema['type']) {
    case 'object':
      if (value is! Map) {
        problems.add('$name must be an object.');
        return;
      }
      final object = asMap(value);
      final props = asMap(schema['properties']);
      for (final r in asList(schema['required'])) {
        if (r is String && object[r] == null) problems.add('"${_joinPath(path, r)}" is required.');
      }
      for (final entry in object.entries) {
        final child = props[entry.key];
        if (child == null) {
          if (schema['additionalProperties'] == false) {
            problems.add('"${_joinPath(path, entry.key)}" isn\'t one of this tool\'s inputs.');
          }
          continue;
        }
        if (entry.value == null) continue;
        _checkValue(asMap(child), entry.value, _joinPath(path, entry.key), problems);
      }
    case 'array':
      if (value is! List) {
        problems.add('$name must be a list.');
        return;
      }
      final max = schema['maxItems'];
      if (max is int && value.length > max) problems.add('$name may have at most $max items.');
      final min = schema['minItems'];
      if (min is int && value.length < min) problems.add('$name needs at least $min items.');
      final items = asMap(schema['items']);
      if (items.isEmpty) return;
      for (var i = 0; i < value.length; i++) {
        _checkValue(items, value[i], '${path.isEmpty ? 'item' : path}[$i]', problems);
      }
    case 'string':
      if (value is! String) {
        problems.add('$name must be text.');
        return;
      }
      final allowed = schema['enum'];
      if (allowed is List && !allowed.contains(value)) {
        problems.add('$name must be one of ${allowed.map((Object? v) => '"$v"').join(', ')}.');
      }
    case 'integer':
      if (!(value is int || (value is double && value == value.roundToDouble()))) {
        problems.add('$name must be a whole number.');
      }
    case 'number':
      if (value is! num) problems.add('$name must be a number.');
    case 'boolean':
      if (value is! bool) problems.add('$name must be true or false.');
  }
}
