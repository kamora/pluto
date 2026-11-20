// coerce() and parse(): the three coercion passes (optional nulls, TypeBox's conversion rules, primitive coercion by
// type), their order where they conflict, and the guarantees around them. Ported from pi-schema's coercion tests,
// with plain schemas where pi uses its builders, and without the tests for TypeBox's own types and JavaScript's
// bigint and undefined.

import 'package:pluto/pluto.dart';
import 'package:test/test.dart';

/// A closed object schema whose properties are required, except those in `optional`; `open` allows other properties.
Map<String, Object?> obj(Map<String, Object?> properties, {List<String> optional = const [], bool open = false}) {
  return {
    'type': 'object',
    'properties': properties,
    'required': [
      for (final k in properties.keys)
        if (!optional.contains(k)) k,
    ],
    if (!open) 'additionalProperties': false,
  };
}

Map<String, Object?> arr(Object items) => {'type': 'array', 'items': items};

const number = {'type': 'number'};
const integer = {'type': 'integer'};
const string = {'type': 'string'};

Object? coerce(Object schema, Object? value) => compile(schema).coerce(value);

/// The coerced `value` property of `{value}` under an object schema with one required property `value`.
Object? coerceValue(Object schema, Object? value) {
  final root = {
    'type': 'object',
    'properties': {'value': schema},
    'required': ['value'],
  };
  return (coerce(root, {'value': value}) as Map)['value'];
}

/// A valid result with `value`.
Matcher valid(Object? value) => isA<Valid>().having((r) => r.value, 'value', value);

/// An invalid result with `errors`.
Matcher invalid(List<ValidationError> errors) => isA<Invalid>().having((r) => r.errors, 'errors', errors);

void main() {
  group('coerce', () {
    test('never modifies the value', () {
      final value = {'count': '42', 'tags': 'a'};
      final schema = obj({'count': number, 'tags': arr(string)});
      expect(coerce(schema, value), {
        'count': 42,
        'tags': ['a'],
      });
      expect(value, {'count': '42', 'tags': 'a'});
    });

    test('returns the value itself when nothing changes', () {
      final value = {
        'a': {
          'b': [1, 2],
        },
        'c': 'x',
      };
      final schema = obj({
        'a': obj({'b': arr(number)}),
        'c': string,
      });
      expect(coerce(schema, value), same(value));
    });

    test('copies only the changed paths', () {
      final unchanged = {
        'b': [1, 2],
      };
      final value = {
        'a': unchanged,
        'c': {'d': '1'},
      };
      final schema = obj({
        'a': obj({'b': arr(number)}),
        'c': obj({'d': number}),
      });
      final coerced = coerce(schema, value) as Map;
      expect(coerced, {
        'a': {
          'b': [1, 2],
        },
        'c': {'d': 1},
      });
      expect(coerced, isNot(same(value)));
      expect(coerced['a'], same(unchanged));
      expect(value['c'], {'d': '1'});
    });

    test('works on unmodifiable schemas and values', () {
      final schema = Map<String, Object?>.unmodifiable({
        'type': 'object',
        'properties': Map<String, Object?>.unmodifiable({'n': Map<String, Object?>.unmodifiable(integer)}),
      });
      expect(coerce(schema, Map<String, Object?>.unmodifiable({'n': '7'})), {'n': 7});
    });

    test('leaves values it cannot coerce for the check to report', () {
      final validator = compile(obj({'count': number}));
      final coerced = validator.coerce({'count': 'many'});
      expect(coerced, {'count': 'many'});
      expect(validator.check(coerced), isFalse);
    });

    test('gives whole numbers as ints', () {
      expect(coerceValue(number, '42'), isA<int>());
      expect(coerceValue(number, '1e3'), allOf(isA<int>(), 1000));
      expect(coerceValue(number, '1.5'), 1.5);
      expect(coerceValue(integer, '3.0'), isA<int>());
      expect(coerceValue(integer, 3.0), allOf(isA<int>(), 3));
    });

    test("reads numbers as JavaScript's Number() does", () {
      expect(coerceValue(number, '0x10'), 16);
      expect(coerceValue(number, '0b101'), 5);
      expect(coerceValue(number, ' 12 '), 12);
      expect(coerceValue(number, '.5'), 0.5);
      expect(coerceValue(number, '1.'), 1);
      expect(coerceValue(number, 'Infinity'), 'Infinity');
      expect(coerceValue(number, '12abc'), '12abc');
      expect(coerceValue(number, '12n'), 12);
    });
  });

  group('parse', () {
    test('returns the coerced value when it is valid', () {
      final validator = compile(obj({'count': number, 'tags': arr(string)}));
      expect(
        validator.parse({'count': '42', 'tags': 'a'}),
        valid({
          'count': 42,
          'tags': ['a'],
        }),
      );
    });

    test('returns the errors of the coerced value when it is invalid', () {
      final validator = compile(obj({'count': number, 'name': string}));
      expect(
        validator.parse({'count': 'many', 'name': 7}),
        invalid([const ValidationError('/count', 'type', 'expected number, got string')]),
      );
    });
  });

  group('validate', () {
    test('checks without coercing', () {
      final validator = compile(obj({'count': number, 'tags': arr(string)}));
      final value = {
        'count': 42,
        'tags': ['a'],
      };
      expect(validator.validate(value), isA<Valid>().having((r) => r.value, 'value', same(value)));

      // parse() would turn "42" into 42 and "a" into ["a"]; validate() reports both.
      expect(
        validator.validate({'count': '42', 'tags': 'a'}),
        invalid([
          const ValidationError('/count', 'type', 'expected number, got string'),
          const ValidationError('/tags', 'type', 'expected array, got string'),
        ]),
      );
    });
  });

  group('pass 1: optional nulls', () {
    test('drops null in optional non-nullable properties, also nested', () {
      final schema = obj(
        {
          'path': string,
          'offset': number,
          'nullable': {
            'anyOf': [
              string,
              {'type': 'null'},
            ],
          },
          'metadata': obj(
            {
              'enabled': {'type': 'boolean'},
            },
            optional: ['enabled'],
          ),
        },
        optional: ['offset', 'nullable'],
        open: true,
      );
      expect(
        coerce(schema, {
          'path': 'file.txt',
          'offset': null,
          'nullable': null,
          'metadata': {'enabled': null},
        }),
        {'path': 'file.txt', 'nullable': null, 'metadata': {}},
      );
    });

    test(r'keeps a null whose property is a $ref (the reference may allow it)', () {
      final schema = {
        'type': 'object',
        'properties': {
          'value': {r'$ref': r'#/$defs/value'},
        },
        r'$defs': {
          'value': {
            'anyOf': [
              number,
              {'type': 'null'},
            ],
          },
        },
      };
      expect(coerce(schema, {'value': null}), {'value': null});
    });

    test('walks array items', () {
      final schema = arr(obj({'a': string, 'b': integer}, optional: ['b']));
      expect(
        coerce(schema, [
          {'a': 'x', 'b': null},
        ]),
        [
          {'a': 'x'},
        ],
      );
    });
  });

  group("pass 2: TypeBox's conversion rules on JSON Schema", () {
    test('converts primitives by type', () {
      expect(coerceValue(number, '42'), 42);
      expect(coerceValue(number, ''), 0);
      expect(coerceValue(number, 'true'), 1);
      expect(coerceValue(integer, '3.5'), 3);
      expect(coerceValue(integer, 1.5), 1);
      expect(coerceValue({'type': 'boolean'}, '1'), true);
      expect(coerceValue({'type': 'boolean'}, 'FALSE'), false);
      expect(coerceValue({'type': 'null'}, 'null'), null);
      expect(coerceValue(string, 42), '42');
    });

    test('wraps a single value into an array and converts the items', () {
      expect(coerceValue(arr(number), '1'), [1]);
      expect(coerceValue(arr(string), null), ['null']);
    });

    test('converts tuple items in place and never wraps for a tuple', () {
      final tuple = {
        'type': 'array',
        'prefixItems': [
          number,
          {'type': 'boolean'},
        ],
        'items': false,
      };
      expect(coerceValue(tuple, ['1', 'true']), [1, true]);
      expect(coerceValue(tuple, '1'), '1');
    });

    test('converts const and enum values only when the result is a member', () {
      expect(coerceValue({'const': 1}, '1'), 1);
      expect(coerceValue({'const': 1}, '2'), '2');
      expect(
        coerceValue({
          'enum': [1, 2, 'hello'],
        }, '2'),
        2,
      );
      expect(
        coerceValue({
          'enum': [1, 2, 'hello'],
        }, 'world'),
        'world',
      );
    });

    test('keeps a value one union branch accepts, else takes the first branch whose conversion the union accepts', () {
      final union = {
        'anyOf': [
          number,
          {'type': 'null'},
        ],
      };
      expect(coerceValue(union, null), null);
      expect(coerceValue(union, '42'), 42);
      expect(coerceValue(union, 'null'), null);
      expect(
        coerceValue({
          'oneOf': [
            {'type': 'boolean'},
            number,
          ],
        }, '1'),
        true,
      );
    });

    test('converts allOf with each member in turn', () {
      final schema = {
        'allOf': [
          obj({'a': number}, open: true),
          obj({
            'b': {'type': 'boolean'},
          }, open: true),
        ],
      };
      expect(coerce(schema, {'a': '1', 'b': 'true'}), {'a': 1, 'b': true});
    });

    test(r'follows $ref', () {
      final schema = {
        'type': 'object',
        'properties': {
          'item': {r'$ref': r'#/$defs/item'},
        },
        r'$defs': {
          'item': {
            'type': 'object',
            'properties': {'id': integer},
          },
        },
      };
      expect(
        coerce(schema, {
          'item': {'id': '7'},
        }),
        {
          'item': {'id': 7},
        },
      );
    });

    test(r'follows a relative $ref from the root $id on the first call of a schema with $dynamicRef', () {
      final schema = {
        r'$id': 'https://example.com/root.json',
        r'$dynamicAnchor': 'node',
        'type': 'object',
        'properties': {
          'count': {r'$ref': 'defs/n.json'},
          'children': {
            'type': 'array',
            'items': {r'$dynamicRef': '#node'},
          },
        },
      };
      final schemas = {'https://example.com/defs/n.json': integer};
      expect(compile(schema, schemas: schemas).coerce({'count': '2'}), {'count': 2});
      final validator = compile(schema, schemas: schemas);
      expect(validator.parse({'count': '2'}), valid({'count': 2}));
      expect(validator.parse({'count': '2'}), valid({'count': 2}));
    });

    test('converts patternProperties and additionalProperties', () {
      final schema = {
        'type': 'object',
        'properties': {'a': number},
        'patternProperties': {'^n_': number},
        'additionalProperties': {'type': 'boolean'},
      };
      expect(coerce(schema, {'a': '1', 'n_x': '2', 'other': 'true'}), {'a': 1, 'n_x': 2, 'other': true});
    });
  });

  group('pass 3: primitive coercion by type', () {
    test("coerces like Ajv's coerceTypes", () {
      final cases = <(Object, Object?, Object?)>[
        (number, true, 1),
        (number, null, 0),
        (integer, '42', 42),
        ({'type': 'boolean'}, 'true', true),
        ({'type': 'boolean'}, 0, false),
        (string, true, 'true'),
        ({'type': 'null'}, '', null),
        ({'type': 'null'}, 0, null),
        ({'type': 'null'}, false, null),
      ];
      for (final (schema, input, expected) in cases) {
        expect(coerceValue(schema, input), expected, reason: '$schema: $input');
      }
    });

    test("leaves a value that matches one of a type array's types, else takes the first coercible type", () {
      expect(
        coerceValue({
          'type': ['number', 'string'],
        }, '1'),
        '1',
      );
      expect(
        coerceValue({
          'type': ['boolean', 'number'],
        }, '1'),
        1,
      );
      expect(
        coerceValue({
          'type': ['integer', 'null'],
        }, '5'),
        5,
      );
    });

    test('accepts null for nullable array schemas with items', () {
      expect(
        coerceValue({
          'type': ['array', 'null'],
          'items': string,
        }, null),
        null,
      );
    });

    test('coerces nullable unions when the value matches no branch', () {
      expect(
        coerceValue({
          'anyOf': [
            number,
            {'type': 'null'},
          ],
        }, '42'),
        42,
      );
      expect(
        coerceValue({
          'oneOf': [
            number,
            {'type': 'null'},
          ],
        }, null),
        null,
      );
    });

    test('leaves values no rule coerces', () {
      final validator = compile({
        'type': 'object',
        'properties': {'value': integer},
        'required': ['value'],
      });
      for (final input in [
        'abc',
        '4x',
        {},
        ['1', '2'],
      ]) {
        expect(validator.check(validator.coerce({'value': input})), isFalse, reason: '$input');
      }
    });
  });

  group('where the passes conflict, the conversion rules win', () {
    test("turns null into 'null' for a required string (pass 3 alone would give '')", () {
      expect(coerceValue(string, null), 'null');
    });

    test("turns '' into 0 for a number (pass 3 leaves an empty string)", () {
      expect(coerceValue(number, ''), 0);
    });

    test("turns '1' and '0' into booleans (pass 3 takes only 'true', 'false', 1 and 0)", () {
      expect(coerceValue({'type': 'boolean'}, '0'), false);
    });

    test("truncates '42.1' for an integer (pass 3 rejects it)", () {
      expect(coerceValue(integer, '42.1'), 42);
    });

    test("drops an optional null before converting it (pass 2 alone would give 'null')", () {
      expect(coerce(obj({'name': string}, optional: ['name']), {'name': null}), {});
    });
  });

  group('recursive schemas', () {
    final tree = {
      'type': 'object',
      'properties': {
        't': {r'$ref': r'#/$defs/Tree'},
      },
      r'$defs': {
        'Tree': {
          'anyOf': [
            string,
            arr({r'$ref': r'#/$defs/Tree'}),
          ],
        },
      },
    };
    final json = {
      'type': 'object',
      'properties': {
        'data': {r'$ref': r'#/$defs/Json'},
      },
      'required': ['data'],
      r'$defs': {
        'Json': {
          'anyOf': [
            string,
            number,
            {'type': 'boolean'},
            arr({r'$ref': r'#/$defs/Json'}),
            {
              'type': 'object',
              'additionalProperties': {r'$ref': r'#/$defs/Json'},
            },
          ],
        },
      },
    };

    test('convert through a recursive union by its first accepting branch', () {
      final validator = compile(tree);
      expect(
        validator.parse({
          't': [
            'a',
            ['b'],
          ],
        }),
        valid({
          't': [
            'a',
            ['b'],
          ],
        }),
      );
      expect(validator.parse({'t': 5}), valid({'t': '5'}));
      expect(
        validator.parse({
          't': [5],
        }),
        valid({
          't': ['5'],
        }),
      );
      expect(
        compile(json).parse({
          'data': {
            'a': [1, null],
          },
        }),
        valid({
          'data': {
            'a': [1, 'null'],
          },
        }),
      );
    });

    test('leave a value a recursive schema cannot convert as it is, for the check to report', () {
      final validator = compile(tree);
      expect(validator.parse({'t': {}}), isA<Invalid>());
      expect(
        validator.coerce({
          't': {'a': 1},
        }),
        {
          't': {'a': 1},
        },
      );
    });

    test('convert a scalar-or-array schema that refers to itself', () {
      final validator = compile({
        'type': 'object',
        'properties': {
          'value': {
            'anyOf': [
              number,
              arr({r'$ref': '#/properties/value'}),
            ],
          },
        },
        'required': ['value'],
      });
      expect(validator.parse({'value': '42'}), valid({'value': 42}));
      expect(
        validator.parse({
          'value': [
            '1',
            ['2'],
          ],
        }),
        valid({
          'value': [
            1,
            [2],
          ],
        }),
      );
      expect(validator.parse({'value': {}}), isA<Invalid>());
    });

    test('stop at a schema that cycles through shared maps instead of \$ref', () {
      final branches = <Object?>[number];
      final node = {'anyOf': branches};
      branches.add(arr(node));
      final validator = compile(node);
      expect(validator.parse('42'), valid(42));
      expect(
        validator.parse([
          '1',
          ['2'],
        ]),
        valid([
          1,
          [2],
        ]),
      );
      expect(validator.parse({}), isA<Invalid>());
    });

    test('reset the re-entry state between calls and leave the input unchanged', () {
      final validator = compile({
        'anyOf': [
          number,
          arr({r'$ref': '#'}),
        ],
      });
      for (var i = 0; i < 20; i++) {
        expect(validator.parse({}), isA<Invalid>());
        expect(validator.parse('42'), valid(42));
        final input = [
          1,
          '2',
          ['3'],
        ];
        expect(
          validator.parse(input),
          valid([
            1,
            2,
            [3],
          ]),
        );
        expect(input, [
          1,
          '2',
          ['3'],
        ]);
      }
    });

    test('convert and explain a deep value that every branch of a recursive union rejects, in linear time', () {
      // Each object branch converts and explains every child: without memoizing per call this is 2^depth work.
      final s = {
        'anyOf': [
          {
            'type': 'object',
            'additionalProperties': {r'$ref': r'#/$defs/S'},
            'required': ['a'],
          },
          {
            'type': 'object',
            'additionalProperties': {r'$ref': r'#/$defs/S'},
            'required': ['b'],
          },
        ],
      };
      final validator = compile({
        'type': 'object',
        'properties': {
          's': {r'$ref': r'#/$defs/S'},
        },
        r'$defs': {'S': s},
      });
      Object value = {'x': 1};
      for (var i = 0; i < 40; i++) {
        value = {'c': value};
      }

      expect(
        validator.parse({'s': value}),
        invalid([
          for (var i = 0; i <= 40; i++) ValidationError('/s${'/c' * i}/a', 'required', 'missing'),
          ValidationError('/s${'/c' * 40}/x', 'type', 'expected object, got integer'),
        ]),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('member keywords across the passes', () {
    test('keep a pattern-matched property from additionalProperties in every pass', () {
      final record = {
        'type': 'object',
        'patternProperties': {'^.*\$': number},
        'additionalProperties': string,
      };
      expect(compile(record).parse({'n1': '1'}), valid({'n1': 1}));
      final plain = {
        'type': 'object',
        'patternProperties': {
          '^n_': {
            'type': ['integer', 'null'],
          },
        },
        'additionalProperties': string,
      };
      expect(coerce(plain, {'n_a': '5', 'other': 7}), {'n_a': 5, 'other': '7'});
    });

    test('drop optional nulls inside declared, pattern and additional property values alike', () {
      final item = obj(
        {
          'n': {'type': 'integer', 'minimum': 1},
        },
        optional: ['n'],
      );
      final schemas = [
        obj({'entry': item}),
        {'type': 'object', 'additionalProperties': item},
        {
          'type': 'object',
          'patternProperties': {r'^entry$': item},
          'additionalProperties': false,
        },
      ];
      for (final schema in schemas) {
        final input = {
          'entry': {'n': null},
        };
        expect(compile(schema).parse(input), valid({'entry': {}}));
        expect(input, {
          'entry': {'n': null},
        });
      }
    });

    test('keep a null under pattern and additional properties: their keys are not optional properties', () {
      final schema = {
        'type': 'object',
        'additionalProperties': {
          'type': ['integer', 'null'],
        },
      };
      expect(compile(schema).parse({'n': null}), valid({'n': null}));
    });

    test('drop optional nulls in tuple items as in array items', () {
      final item = obj({'n': integer}, optional: ['n']);
      expect(
        compile(arr(item)).coerce([
          {'n': null},
        ]),
        [{}],
      );
      expect(
        compile({
          'type': 'array',
          'prefixItems': [item],
          'items': false,
        }).coerce([
          {'n': null},
        ]),
        [{}],
      );
    });

    test('coerce tuple items by type in pass 3', () {
      final schema = {
        'type': 'array',
        'prefixItems': [
          {
            'type': ['integer', 'null'],
          },
          {
            'type': ['boolean', 'null'],
          },
        ],
      };
      expect(coerce(schema, ['5', 'true']), [5, true]);
    });

    test('convert the properties a union node declares besides its branches', () {
      final schema = {
        'type': 'object',
        'properties': {'a': integer, 'b': integer},
        'anyOf': [
          {
            'required': ['a'],
          },
          {
            'required': ['b'],
          },
        ],
      };
      expect(compile(schema).parse({'a': '3.5'}), valid({'a': 3}));
    });

    for (final keyword in ['anyOf', 'oneOf']) {
      test("check $keyword candidates after the node's own properties convert", () {
        final schema = {
          'type': 'object',
          keyword: [
            {
              'type': 'object',
              'properties': {'a': arr(integer)},
              'required': ['a'],
            },
            {
              'type': 'object',
              'properties': {
                'b': {'type': 'boolean'},
              },
              'required': ['b'],
            },
          ],
          'properties': {'c': integer},
          'required': ['c'],
        };
        final input = {'a': '3', 'c': '2'};
        expect(
          compile(schema).parse(input),
          valid({
            'a': [3],
            'c': 2,
          }),
        );
        expect(input, {'a': '3', 'c': '2'});
      });
    }
  });
}
