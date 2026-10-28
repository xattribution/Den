import 'package:den_assistant/den_assistant.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('portable subset', () {
    test('a plain schema passes', () {
      expect(checkTool(addItems), isEmpty);
      expect(checkTool(getToday), isEmpty);
      expect(
        checkPortableSchema({
          'type': 'object',
          'properties': {
            'scope': {
              'type': 'string',
              'enum': ['one', 'following', 'all'],
            },
            'delta': {'type': 'integer', 'minimum': -100, 'maximum': 100},
          },
          'required': ['delta'],
          'additionalProperties': false,
        }),
        isEmpty,
      );
    });

    test('flags what some provider won\'t take', () {
      // Today's MCP add_items takes text or an object per item, through anyOf.
      final issues = checkPortableSchema({
        'type': 'object',
        r'$schema': 'https://json-schema.org/draft/2020-12/schema',
        'properties': {
          'items': {
            'type': 'array',
            'items': {
              'anyOf': [
                {'type': 'string'},
                {'type': 'object'},
              ],
            },
          },
          'when': {
            'type': ['string', 'null'],
          },
          'count': {
            'type': 'integer',
            'enum': [1, 2],
          },
          'tags': {'type': 'array'},
          'meta': {'type': 'object', 'additionalProperties': true},
          'bad name': {'type': 'string'},
          'ref': {r'$ref': '#/defs/x'},
        },
        'required': ['items', 'missing'],
      });
      final paths = [for (final i in issues) i.path];
      expect(paths, contains(r'$schema'));
      expect(paths, contains('properties.items.items.anyOf'));
      expect(paths, contains('properties.items.items.type'));
      expect(paths, contains('properties.when.type'));
      expect(paths, contains('properties.count.enum'));
      expect(paths, contains('properties.tags.items'));
      expect(paths, contains('properties.meta.additionalProperties'));
      expect(paths, contains('properties.meta.properties'));
      expect(paths, contains('properties.bad name'));
      expect(paths, contains(r'properties.ref.$ref'));
      expect(paths, contains('required'));
      expect(issues.firstWhere((i) => i.path == 'required').message, contains('"missing"'));
    });

    test('flags a top level that isn\'t an object, and bad tool names', () {
      expect(checkPortableSchema({'type': 'string'}).map((i) => i.path), contains('type'));
      final tool = AssistantTool(name: 'add-items!', description: '', input: AssistantTool.emptyInput);
      expect(checkTool(tool).map((i) => i.path), containsAll(['name', 'description']));
    });
  });

  group('per provider', () {
    test('JSON Schema providers get the schema with an object on top', () {
      expect(jsonSchemaFor(addItems.input), addItems.input);
      expect(jsonSchemaFor(const {}), {'type': 'object', 'properties': <String, Object?>{}});
    });

    test('Gemini gets upper-case types, nullable, enum format, and nothing it rejects', () {
      final schema = geminiSchemaFor({
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'scope': {
            'type': 'string',
            'enum': ['one', 'all'],
            'description': 'Which.',
          },
          'when': {
            'type': ['string', 'null'],
          },
          'list': {
            'type': 'array',
            'items': {'type': 'integer', 'minimum': 1},
          },
        },
        'required': ['scope'],
      });
      expect(schema, {
        'type': 'OBJECT',
        'properties': {
          'scope': {
            'type': 'STRING',
            'enum': ['one', 'all'],
            'format': 'enum',
            'description': 'Which.',
          },
          'when': {'type': 'STRING', 'nullable': true},
          'list': {
            'type': 'ARRAY',
            'items': {'type': 'INTEGER', 'minimum': 1},
          },
        },
        'required': ['scope'],
      });
      expect(geminiSchemaFor(AssistantTool.emptyInput), isNull);
    });
  });

  group('checkInput', () {
    test('accepts what fits', () {
      expect(
        checkInput(addItems.input, {
          'list': 'Groceries',
          'items': [
            {'text': 'Eggs', 'qty': '12'},
          ],
        }),
        isEmpty,
      );
      expect(
        checkInput({
          'type': 'object',
          'properties': {
            'n': {'type': 'integer'},
          },
        }, {'n': 2.0}),
        isEmpty,
      );
    });

    test('explains what doesn\'t', () {
      final problems = checkInput(addItems.input, {
        'items': [
          {'qty': 2},
          'Eggs',
        ],
      });
      expect(problems, contains('"list" is required.'));
      expect(problems, contains('"items[0].text" is required.'));
      expect(problems, contains('"items[0].qty" must be text.'));
      expect(problems, contains('"items[1]" must be an object.'));

      final closed = {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'scope': {
            'type': 'string',
            'enum': ['one', 'all'],
          },
          'n': {'type': 'integer'},
          'on': {'type': 'boolean'},
        },
      };
      final more = checkInput(closed, {'scope': 'some', 'n': 1.5, 'on': 'yes', 'extra': 1});
      expect(more, contains('"scope" must be one of "one", "all".'));
      expect(more, contains('"n" must be a whole number.'));
      expect(more, contains('"on" must be true or false.'));
      expect(more, contains('"extra" isn\'t one of this tool\'s inputs.'));
    });
  });
}
