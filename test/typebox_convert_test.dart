// TypeBox 1.3.27's Value.Convert tests (test/typebox/runtime/value/convert, MIT, (c) Haydn Paterson), as pi-schema
// ports them, run against the conversion pass. `fixtures/typebox-convert.json` holds every case whose schema, value
// and expected result have a JSON form, recorded from pi-schema's test file with TypeBox building the schemas.

import 'dart:convert';
import 'dart:io';

import 'package:pluto/pluto.dart';
import 'package:pluto/src/coerce.dart';
import 'package:pluto/src/compiler.dart';
import 'package:test/test.dart';

void main() {
  final cases = (jsonDecode(File('test/fixtures/typebox-convert.json').readAsStringSync()) as List)
      .cast<Map<String, Object?>>();
  for (final c in cases) {
    test(c['name'], () {
      final schema = c['schema']!;
      final actual = Coercer(Compiler(schema, Draft.draft2020, null, const {}, false)).convert(c['value']);
      expect(deepEqual(actual, c['expected']), isTrue, reason: 'got ${jsonEncode(actual)}');
    });
  }
}
