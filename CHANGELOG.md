## 0.0.2

- An invalid regular expression in `pattern` or `patternProperties` now throws a `SchemaException` naming the pattern,
  instead of Dart's `FormatException`.

## 0.0.1

- First version: JSON Schema validation (drafts 2020-12 and 7) with error paths, coercion of loosely typed input and
  the format checks of 2020-12. A Dart port of pi-schema 1.5.2.
