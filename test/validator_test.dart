// compile() and Validator: checks, errors, values, options and schemas from other sources. Ported from pi-schema's
// validator tests, without those for TypeBox and its JavaScript types.

import 'dart:convert';

import 'package:pluto/formats.dart';
import 'package:pluto/pluto.dart';
import 'package:test/test.dart';

const read = {
  'type': 'object',
  'properties': {
    'path': {'type': 'string'},
    'offset': {'type': 'integer', 'minimum': 1},
  },
  'required': ['path'],
  'additionalProperties': false,
};

const block = {
  'anyOf': [
    {
      'type': 'object',
      'properties': {
        'kind': {'const': 'text'},
        'text': {'type': 'string'},
      },
      'required': ['kind', 'text'],
      'additionalProperties': false,
    },
    {
      'type': 'object',
      'properties': {
        'kind': {'const': 'image'},
        'width': {'type': 'integer', 'minimum': 0},
      },
      'required': ['kind', 'width'],
      'additionalProperties': false,
    },
  ],
};

void main() {
  group('errors', () {
    test('reports a missing field and an unknown field at the field', () {
      expect(compile(read).errors({'offset': 0, 'extra': true}), [
        const ValidationError('/path', 'required', 'missing'),
        const ValidationError('/offset', 'minimum', 'expected >= 1'),
        const ValidationError('/extra', 'additionalProperties', 'unknown field'),
      ]);
    });

    test('is empty for a valid value', () {
      expect(compile(read).errors({'path': 'a.ts'}), isEmpty);
    });

    test("reports the branch a tagged union's tag selects", () {
      final validator = compile({'type': 'array', 'items': block});
      expect(
        validator.errors([
          {'kind': 'text', 'text': 'a'},
          {'kind': 'image', 'width': -1},
        ]),
        [const ValidationError('/1/width', 'minimum', 'expected >= 0')],
      );
      expect(
        validator.errors([
          {'kind': 'video'},
        ]),
        [const ValidationError('/0/kind', 'anyOf', 'expected one of ["text","image"]')],
      );
    });

    test('escapes ~ and / in paths as JSON Pointer does', () {
      final validator = compile({
        'type': 'object',
        'properties': {
          'a/b~c': {'type': 'string'},
        },
      });
      expect(validator.errors({'a/b~c': 1}), [
        const ValidationError('/a~1b~0c', 'type', 'expected string, got integer'),
      ]);
    });

    test(r'follows $ref into the referenced schema', () {
      final validator = compile({
        r'$defs': {
          'point': {
            'type': 'object',
            'properties': {
              'x': {'type': 'number'},
            },
            'required': ['x'],
          },
        },
        'type': 'array',
        'items': {r'$ref': r'#/$defs/point'},
      });
      expect(
        validator.errors([
          {'x': 1},
          {},
        ]),
        [const ValidationError('/1/x', 'required', 'missing')],
      );
    });
  });

  group('values', () {
    test('treats a property set to null as present, as JSON does', () {
      final validator = compile(read);
      expect(validator.check({'path': 'a.ts', 'offset': null}), isFalse);
      expect(validator.check({'path': null}), isFalse);
    });

    test('rejects NaN and Infinity as a number or an integer, with or without bounds', () {
      final schemas = [
        {'type': 'number'},
        {'type': 'integer'},
        {'type': 'number', 'minimum': 0},
        {
          'type': ['number', 'string'],
        },
        {
          'anyOf': [
            {'type': 'number'},
            {'type': 'null'},
          ],
        },
        {
          'type': 'object',
          'properties': {
            'a': {'type': 'number'},
          },
        },
      ];
      for (final schema in schemas) {
        final check = compile(schema).check;
        for (final v in [double.nan, double.infinity, double.negativeInfinity]) {
          expect(check(schema['type'] == 'object' ? {'a': v} : v), isFalse, reason: '$schema: $v');
        }
      }

      expect(compile({'type': 'number'}).errors(double.nan), [
        const ValidationError('', 'type', 'expected number, got NaN'),
      ]);
    });

    test('counts a number without a fraction as an integer', () {
      final check = compile({'type': 'integer'}).check;
      expect(check(1.0), isTrue);
      expect(check(1.5), isFalse);
      expect(compile({'type': 'integer'}).errors(1.5), [
        const ValidationError('', 'type', 'expected integer, got number'),
      ]);
    });

    test('checks a detached check function', () {
      final check = compile(read).check;
      expect(
        [
          {'path': 'a'},
          {'path': 1},
        ].where(check),
        [
          {'path': 'a'},
        ],
      );
    });
  });

  group('options', () {
    test('treats format as an annotation unless formats are given', () {
      const schema = {'type': 'string', 'format': 'email'};
      expect(compile(schema).check('not an email'), isTrue);
      expect(compile(schema, formats: formats).check('not an email'), isFalse);
      expect(compile(schema, formats: formats).check('a@example.com'), isTrue);
      expect(compile(schema, formats: formats).errors('x'), [
        const ValidationError('', 'format', 'expected format email'),
      ]);
    });

    test(r'resolves $ref to registered documents', () {
      final point = {
        'type': 'object',
        'properties': {
          'x': {'type': 'number'},
        },
        'required': ['x'],
      };
      final validator = compile(
        {r'$ref': 'https://example.com/point.json'},
        schemas: {'https://example.com/point.json': point},
      );
      expect(validator.check({'x': 1}), isTrue);
      expect(validator.check({}), isFalse);
    });

    test(r'throws for a $ref that names nothing', () {
      expect(() => compile({r'$ref': 'https://example.com/missing.json'}), throwsA(_message(r'Unresolved $ref')));
      expect(() => compile({r'$ref': r'#/$defs/missing'}), throwsA(_message(r'Unresolved $ref')));
    });

    test(r'applies draft 7 semantics: $ref overrides its siblings', () {
      final schema = {
        'definitions': {
          's': {'type': 'string'},
        },
        r'$ref': '#/definitions/s',
        'maxLength': 1,
      };
      expect(compile(schema, draft: Draft.draft7).check('ab'), isTrue);
      expect(compile(schema).check('ab'), isFalse);
    });
  });

  group('schemas', () {
    test('compiles unmodifiable schemas and never modifies a schema', () {
      final schema = jsonDecode(
        jsonEncode({
          ...block,
          r'$defs': {
            's': {'type': 'string', 'pattern': '^a'},
          },
        }),
      );
      final before = jsonEncode(schema);
      final validator = compile(_unmodifiable(schema)!);
      expect(validator.check({'kind': 'text', 'text': 'x'}), isTrue);
      expect(validator.errors({'kind': 'image', 'width': -1}), hasLength(1));
      expect(jsonEncode(schema), before);
    });

    test('compiles a recursive schema', () {
      final tree = {
        'type': 'object',
        'properties': {
          'value': {'type': 'number'},
          'children': {
            'type': 'array',
            'items': {r'$ref': '#'},
          },
        },
        'required': ['value'],
      };
      final validator = compile(tree);
      expect(
        validator.check({
          'value': 1,
          'children': [
            {
              'value': 2,
              'children': [
                {'value': 3},
              ],
            },
          ],
        }),
        isTrue,
      );
      expect(
        validator.errors({
          'value': 1,
          'children': [
            {
              'value': 2,
              'children': [{}],
            },
          ],
        }),
        [const ValidationError('/children/0/children/0/value', 'required', 'missing')],
      );
    });

    // pi #11697
    test(r'applies a relative root $id once when resolving local references', () {
      final schema = {
        r'$id': 'schemas/tool.json',
        'type': 'object',
        'properties': {
          'count': {r'$ref': r'#/$defs/count'},
        },
        'required': ['count'],
        r'$defs': {
          'count': {'type': 'integer'},
        },
      };
      expect(compile(schema).check({'count': 2}), isTrue);
      final validator = compile(schema, rejectUnresolved: true);
      expect(validator.check({'count': 2}), isTrue);
      expect(validator.errors({'count': 'a'}), [
        const ValidationError('/count', 'type', 'expected integer, got string'),
      ]);
    });

    test(r'applies a relative root $id once in schemas with unevaluated keywords', () {
      final props = {
        r'$id': 'schemas/tool.json',
        'type': 'object',
        'properties': {
          'count': {r'$ref': r'#/$defs/count'},
        },
        r'$defs': {
          'count': {'type': 'integer'},
        },
        'unevaluatedProperties': false,
      };
      final validator = compile(props, rejectUnresolved: true);
      expect(validator.check({'count': 2}), isTrue);
      expect(validator.errors({'count': 2, 'extra': 1}), [
        const ValidationError('/extra', 'unevaluatedProperties', 'unknown field'),
      ]);
      final items = {
        r'$id': 'schemas/list.json',
        'type': 'array',
        'prefixItems': [
          {r'$ref': r'#/$defs/count'},
        ],
        r'$defs': {
          'count': {'type': 'integer'},
        },
        'unevaluatedItems': false,
      };
      expect(compile(items, rejectUnresolved: true).check([2]), isTrue);
      expect(compile(items).check([2, 3]), isFalse);
    });

    test(r'explains errors under nested resources with a relative $id', () {
      final cloned = {
        r'$id': 'https://example.com/root.json',
        'allOf': [
          {r'$ref': r'#/$defs/child'},
        ],
        r'$defs': {
          'child': {
            r'$id': 'schemas/tool.json',
            r'$ref': r'#/$defs/props',
            'unevaluatedProperties': false,
            r'$defs': {
              'props': {
                'properties': {
                  'count': {'type': 'integer'},
                },
              },
            },
          },
        },
      };
      expect(compile(cloned).errors({'count': 2, 'extra': 1}), [
        const ValidationError('/extra', 'unevaluatedProperties', 'unknown field'),
      ]);
      final branch = {
        r'$id': 'https://example.com/root.json',
        'anyOf': [
          {
            r'$id': 'a/b.json',
            r'$ref': r'#/$defs/n',
            r'$defs': {
              'n': {'type': 'integer'},
            },
          },
          {'type': 'boolean'},
        ],
      };
      expect(compile(branch).errors({}), [const ValidationError('', 'type', 'expected integer, got object')]);
    });

    test('throws for a malformed schema', () {
      expect(
        () => compile({
          'properties': {'a': 1},
        }),
        throwsA(_message('must be an object or a boolean')),
      );
    });

    test('throws for an invalid pattern, in a pattern or a pattern property', () {
      expect(
        () => compile({'type': 'string', 'pattern': '(unclosed'}),
        throwsA(_message('Invalid pattern "(unclosed": Unterminated group')),
      );
      expect(
        () => compile({
          'patternProperties': {'[a-': true},
        }),
        throwsA(_message('Invalid pattern "[a-"')),
      );
    });

    test('a pattern invalid only with Unicode still compiles without it', () {
      expect(compile({'type': 'string', 'pattern': r'\-'}).check('-'), isTrue);
    });
  });

  group('unresolved references', () {
    const dangling = {
      'type': 'object',
      'properties': {
        't': {r'$ref': '#/definitions/Missing'},
      },
    };
    const external = {
      'type': 'object',
      'properties': {
        't': {r'$ref': 'https://example.com/schemas/t.json'},
      },
    };

    test('throw when the schema compiles, by default', () {
      expect(() => compile(dangling), throwsA(_message(r'Unresolved $ref #/definitions/Missing')));
      expect(() => compile(external), throwsA(_message(r'Unresolved $ref https://example.com/schemas/t.json')));
    });

    test('reject only values at their place with rejectUnresolved', () {
      for (final schema in [dangling, external]) {
        final validator = compile(schema, rejectUnresolved: true);
        expect(validator.check({}), isTrue);
        expect(validator.check({'t': 1}), isFalse);
      }

      expect(compile(dangling, rejectUnresolved: true).errors({'t': 1}), [
        const ValidationError('/t', r'$ref', 'unresolved reference #/definitions/Missing'),
      ]);
    });
  });

  group('checks as a property, a pattern property and an item', () {
    final leaves = <(Map<String, Object?>, List<Object?>)>[
      ({'const': 'a'}, ['a', 'b', 1, null]),
      ({'const': null}, [null, 0, false, 'null']),
      (
        {
          'enum': ['a', 1, null],
        },
        ['a', 1, null, 'b', 2, true],
      ),
      (
        {
          'type': ['string', 'null'],
        },
        ['a', null, 1, {}, []],
      ),
      (
        {
          'type': ['integer', 'boolean'],
        },
        [1, 1.5, true, '1'],
      ),
      (
        {
          'type': ['number', 'array'],
        },
        [1.5, 2, [], {}],
      ),
      (
        {
          'anyOf': [
            {'type': 'string'},
            {'type': 'null'},
          ],
        },
        ['a', null, 1],
      ),
      (
        {
          'anyOf': [
            {'type': 'integer'},
            {'type': 'string', 'minLength': 2},
          ],
        },
        [1, 1.5, 'ab', 'a'],
      ),
      ({'type': 'integer', 'minimum': 1, 'exclusiveMaximum': 5}, [1, 4, 5, 0, 2.5, '2']),
      ({'type': 'number', 'exclusiveMinimum': 0, 'maximum': 1}, [0.5, 1, 0, 1.5, '0.5']),
      ({'type': 'integer', 'multipleOf': 2}, [2, 3, 2.5]),
      ({'type': 'string', 'minLength': 2, 'maxLength': 3}, ['ab', 'abc', 'a', 'abcd', '😀😀', 12]),
      ({'type': 'string', 'pattern': r'^a+$'}, ['aa', 'ab', 1]),
      ({'minimum': 1}, [1, 0, 'x', null]),
    ];

    test('agree with the standalone check', () {
      for (final (schema, values) in leaves) {
        final alone = compile(schema).check;
        final closed = compile({
          'type': 'object',
          'properties': {'p': schema},
          'additionalProperties': false,
        }).check;
        final open = compile({
          'type': 'object',
          'properties': {'p': schema},
          'required': ['q'],
        }).check;
        final pattern = compile({
          'type': 'object',
          'patternProperties': {'^p': schema},
        }).check;
        final items = compile({'type': 'array', 'items': schema}).check;
        for (final v in values) {
          final expected = alone(v);
          expect(
            [
              closed({'p': v}),
              open({'p': v, 'q': 1}),
              pattern({'p': v}),
              items([v]),
            ],
            [expected, expected, expected, expected],
            reason: jsonEncode({'schema': schema, 'v': v}),
          );
        }
      }
    });

    test('find properties in any order', () {
      final check = compile({
        'type': 'object',
        'properties': {
          'a': {'const': 1},
          'b': {'type': 'string'},
          'c': {'type': 'integer', 'minimum': 0},
        },
        'required': ['a', 'c'],
        'additionalProperties': false,
      }).check;
      expect(check({'a': 1, 'b': 'x', 'c': 0}), isTrue);
      expect(check({'c': 0, 'b': 'x', 'a': 1}), isTrue);
      expect(check({'b': 'x', 'c': 0, 'a': 1}), isTrue);
      expect(check({'a': 1, 'c': 0, 'a2': 1}), isFalse);
      expect(check({'c': -1, 'a': 1}), isFalse);
      expect(check({'c': 0, 'b': 1, 'a': 1}), isFalse);
      expect(check({'c': 0, 'b': 'x'}), isFalse);
    });
  });

  group('string lengths', () {
    test('count an unpaired high surrogate as one code point and a pair as one', () {
      expect(compile({'type': 'string', 'minLength': 2}).check('\uD800A'), isTrue);
      expect(compile({'type': 'string', 'maxLength': 1}).check('\uD800A'), isFalse);
      expect(compile({'type': 'string', 'maxLength': 1}).check('\uD800'), isTrue);
      expect(compile({'type': 'string', 'maxLength': 1}).check('😀'), isTrue);
      expect(compile({'type': 'string', 'minLength': 2}).check('😀'), isFalse);
      expect(compile({'type': 'string', 'minLength': 2}).check('\uDC00\uD800'), isTrue);
    });
  });

  group('error messages', () {
    test('list at most 20 enum values', () {
      final values = [for (var i = 0; i < 5000; i++) 'v$i'];
      final validator = compile({
        'type': 'object',
        'properties': {
          'e': {'type': 'string', 'enum': values},
        },
      });
      expect(validator.check({'e': 'v4999'}), isTrue);
      final listed = jsonEncode(values.sublist(0, 20));
      expect(
        validator.errors({'e': 'v5000'}).single.message,
        'expected one of ${listed.substring(0, listed.length - 1)}, ... and 4980 more]',
      );
      expect(
        compile({
          'enum': ['a', 'b'],
        }).errors('c'),
        [const ValidationError('', 'enum', 'expected one of ["a","b"]')],
      );
    });

    test('accept a 10,000-value enum', () {
      expect(
        compile({
          'enum': [for (var i = 0; i < 10000; i++) 'member$i'],
        }).check('member9999'),
        isTrue,
      );
    });

    test('describe contains bounds in words', () {
      String at(Map<String, Object?> schema) => compile({'type': 'array', ...schema}).errors(['a']).first.message;

      expect(
        at({
          'contains': {'type': 'number'},
        }),
        'expected at least 1 matching item',
      );
      expect(
        at({
          'contains': {'type': 'number'},
          'minContains': 2,
        }),
        'expected at least 2 matching items',
      );
      expect(
        at({
          'contains': {'type': 'string'},
          'maxContains': 0,
          'minContains': 0,
        }),
        'expected at most 0 matching items',
      );
      expect(
        at({
          'contains': {'type': 'number'},
          'minContains': 1,
          'maxContains': 3,
        }),
        'expected between 1 and 3 matching items',
      );
    });

    test("blame a oneOf failure on the branch that declares most of the object's properties", () {
      final filter = {
        'type': 'object',
        'properties': {
          'where': {r'$ref': r'#/$defs/F'},
        },
        r'$defs': {
          'F': {
            'oneOf': [
              {
                'type': 'object',
                'properties': {
                  'field': {'type': 'string'},
                  'eq': {'type': 'string'},
                },
                'required': ['field', 'eq'],
                'additionalProperties': false,
              },
              {
                'type': 'object',
                'properties': {
                  'and': {
                    'type': 'array',
                    'items': {r'$ref': r'#/$defs/F'},
                  },
                },
                'required': ['and'],
                'additionalProperties': false,
              },
            ],
          },
        },
      };
      expect(
        compile(filter).errors({
          'where': {
            'and': [
              {'field': 'a', 'eq': 1, 'x': 2},
            ],
          },
        }),
        [
          const ValidationError('/where/and/0/eq', 'type', 'expected string, got integer'),
          const ValidationError('/where/and/0/x', 'additionalProperties', 'unknown field'),
        ],
      );
    });

    test('blame a union whose branches share a tag value like any other union', () {
      final validator = compile({
        'anyOf': [
          {
            'type': 'object',
            'properties': {
              'kind': {'const': 'a'},
              'x': {'type': 'string'},
            },
            'required': ['kind', 'x'],
          },
          {
            'type': 'object',
            'properties': {
              'kind': {'const': 'a'},
              'y': {'type': 'integer'},
            },
            'required': ['kind', 'y'],
          },
        ],
      });
      expect(validator.errors({'kind': 'a', 'y': 's'}), [
        const ValidationError('/y', 'type', 'expected integer, got string'),
      ]);
    });

    test('explain one object reached through the same reference at two paths at each path', () {
      final schema = {
        'type': 'object',
        'properties': {
          'a': {r'$ref': r'#/$defs/P'},
          'b': {r'$ref': r'#/$defs/P'},
        },
        r'$defs': {
          'P': {
            'type': 'object',
            'properties': {
              'n': {'type': 'integer'},
            },
          },
        },
      };
      final shared = {'n': 'x'};
      expect(compile(schema).errors({'a': shared, 'b': shared}), [
        const ValidationError('/a/n', 'type', 'expected integer, got string'),
        const ValidationError('/b/n', 'type', 'expected integer, got string'),
      ]);
    });
  });

  group('deepEqual', () {
    test('compares JSON values structurally', () {
      final cases = <(Object?, Object?, bool)>[
        (1, 1, true),
        (1, 1.0, true),
        ('a', 'b', false),
        (null, null, true),
        (
          {
            'a': 1,
            'b': [
              1,
              {'c': 2},
            ],
          },
          {
            'b': [
              1,
              {'c': 2},
            ],
            'a': 1,
          },
          true,
        ),
        ({'a': 1}, {'a': 1, 'b': 2}, false),
        ([1, 2], [2, 1], false),
        ([1], {'0': 1}, false),
        ({}, [], false),
        ({'a': null}, {}, false),
        (true, 1, false),
      ];
      for (final (a, b, equal) in cases) {
        expect(deepEqual(a, b), equal, reason: '$a, $b');
      }
    });
  });
}

Matcher _message(String text) => isA<SchemaException>().having((e) => e.message, 'message', contains(text));

// A deep copy of a decoded JSON value whose maps and lists cannot be modified.
Object? _unmodifiable(Object? value) {
  return switch (value) {
    Map() => Map.unmodifiable({for (final MapEntry(:key, :value) in value.entries) key: _unmodifiable(value)}),
    List() => List.unmodifiable([for (final v in value) _unmodifiable(v)]),
    _ => value,
  };
}
