# pluto

JSON Schema validation for Dart, drafts 2020-12 and 7, with errors as JSON Pointer paths and opt-in coercion of
loosely typed input, such as a language model's tool call arguments. No dependencies.

A Dart port of [pi-schema](https://github.com/earendil-works/pi/tree/main/packages/schema) 1.5.2 by Earendil Works,
the validator of the pi agent toolkit. Not an official package of pi.

- Passes 2,222 of the 2,223 core tests of the official
  [JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite), as pi-schema does.
- Standard JSON Schema only: schemas are plain JSON (`true`, `false` or a map), as `jsonDecode` returns them.
- Never modifies a schema or a value.

## Usage

```dart
import 'package:pluto/pluto.dart';

final read = compile({
  'type': 'object',
  'properties': {
    'path': {'type': 'string', 'minLength': 1},
    'offset': {'type': 'integer', 'minimum': 1},
  },
  'required': ['path'],
  'additionalProperties': false,
});

read.check({'path': 'a.txt'}); // true

read.errors({'offset': 0, 'extra': true});
// /path: missing (required)
// /offset: expected >= 1 (minimum)
// /extra: unknown field (additionalProperties)
```

`check(value)` is the fast path: a boolean, and a plain function that can be passed around. `errors(value)` explains a
failure, one error per failing keyword, and is empty for a valid value; it is built on the first failure. `validate`
returns both as one result: `Valid(value)` or `Invalid(errors)`.

### Options

```dart
import 'package:pluto/formats.dart';

final validator = compile(
  schema,
  draft: Draft.draft7, // Draft.draft2020 (2020-12) by default
  formats: formats, // check `format`; without it `format` is an annotation, as 2020-12 specifies
  schemas: {'https://example.com/point.json': point}, // documents for $refs to other documents, by URI
  rejectUnresolved: true, // a $ref that names nothing rejects values at its place instead of throwing
);
```

`formats` has every format 2020-12 defines (`date-time`, `email`, `uri`, `uuid`, `ipv6`, ...). Pass your own map to
check fewer formats, or custom ones.

A `$ref` that names nothing (a missing definition, a document not in `schemas`) throws a `SchemaException` when the
schema compiles. With `rejectUnresolved` it compiles as `false` instead: only values at that place fail, with the error
`unresolved reference <ref>`, and the rest of the schema works. Use it for schemas from other systems, such as MCP
servers, whose references may dangle.

### Coercion

`coerce(value)` turns a loosely typed value into the value the schema most likely meant; `parse(value)` coerces, then
validates. Validation itself never changes a value.

```dart
read.parse({'path': 'a.txt', 'offset': '10'}); // Valid({path: a.txt, offset: 10})
read.parse({'path': 'a.txt', 'offset': 'ten'}); // Invalid([/offset: expected integer, got string (type)])
```

`coerce` copies only the paths it changes and returns the value itself when nothing changes. A value no rule applies to
stays as it is, for the check to report. Three passes run in order:

1. **Optional nulls.** A `null` in an optional property whose schema rejects `null` is dropped, as if omitted.
2. **Conversions**, ported from TypeBox 1.3.27's `Value.Convert`, keyed on JSON Schema keywords (the first that
   applies): `$ref` follows the reference; `const` and `enum` take the member the value converts to; `anyOf`/`oneOf`
   keep a value one branch accepts, else take the first branch's conversion the whole schema accepts; `allOf`
   converts with each member in turn; then by `type`:
   - `string`: numbers and booleans to their text, `null` to `"null"`.
   - `number`: numeric strings (`""` is 0), `"true"`/`"false"`, booleans to 1/0, `null` to 0.
   - `integer`: as `number`, then truncated (`"3.5"` and `3.5` become 3).
   - `boolean`: `"true"`/`"false"` (any case), `"1"`/`"0"`, 1/0, `null` to `false`.
   - `null`: `"null"`, `"undefined"`, `""`, `"0"`, 0 and `false`.
   - `array`: a single value becomes a one-item list, then each item converts; a tuple (`prefixItems` or an `items`
     array) converts its items and never wraps.
   - `object`: each property converts by `properties`, `patternProperties` or `additionalProperties`.
3. **Primitive coercion by type**, as Ajv's `coerceTypes`, for what pass 2 leaves (type arrays such as
   `["integer", "null"]`): numbers from numeric strings and booleans, booleans from `"true"`/`"false"` and 1/0,
   strings from numbers and booleans, `null` from `""`, 0 and `false`, and `null` to `""`, 0 or `false`. A value that
   already has one of a type array's types stays.

Where passes 2 and 3 disagree, pass 2 wins: `null` for a required string becomes `"null"`, not `""`. Numeric strings
are read as JavaScript's `Number()` reads them, and a whole number comes back as an `int`.

## Differences from pi-schema

- **Standard JSON Schema only.** No schema builders (they exist for TypeScript's static types), no TypeBox schemas,
  and none of pi-schema's extensions for JavaScript values: the `bytes`, `bigint` and `undefined` types, and the `url`
  and `json-pointer-uri-fragment` formats.
- **Coercion is always available.** pi-schema adds `coerce()` and `parse()` only with `coerce: true`; here they are
  methods of every validator, built on their first call.
- **No Unicode normalization.** `idn-email` and `idn-hostname` check a value as it is, without NFC first: Dart's core
  libraries have none. Two optional format tests of the suite fail for it.
- **`iri` and `iri-reference`** are checked with Dart's `Uri` where pi-schema uses the WHATWG URL parser; both pass the
  suite's tests.

## Tests

```sh
dart test
dart run tool/suite.dart # every test of the suite, with the pass counts per draft
```

The tests are pi-schema's own, ported: the official JSON-Schema-Test-Suite (vendored in `test/fixtures`, MIT), its
validator and coercion tests, and TypeBox's `Value.Convert` tests, recorded as JSON from pi-schema's port of them.

## License

MIT, as pi. The format checks and the conversion rules are adapted from TypeBox (MIT, Haydn Paterson); its notice is in
`THIRD_PARTY_NOTICES`.
