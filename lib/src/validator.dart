// compile(): a schema to a Validator, whose `check` is the fast boolean path and whose `errors` explains failures.

import 'checks.dart';
import 'coerce.dart';
import 'compiler.dart';
import 'explain.dart';

/// The JSON Schema draft whose semantics apply.
enum Draft {
  /// Draft 2020-12, the default.
  draft2020,

  /// Draft 7.
  draft7,
}

/// A format check: whether `value` has the format.
typedef FormatCheck = bool Function(String value);

/// A schema that cannot be compiled: malformed, or with a `$ref` that names nothing.
class SchemaException implements Exception {
  SchemaException(this.message);

  final String message;

  @override
  String toString() => 'SchemaException: $message';
}

/// One failure of a value: where it is (a JSON Pointer, "" for the value itself), the failing keyword and a message.
class ValidationError {
  const ValidationError(this.path, this.keyword, this.message);

  final String path;
  final String keyword;
  final String message;

  @override
  bool operator ==(Object other) {
    return other is ValidationError && other.path == path && other.keyword == keyword && other.message == message;
  }

  @override
  int get hashCode => Object.hash(path, keyword, message);

  @override
  String toString() => '$path: $message ($keyword)';
}

/// The result of `validate()` and `parse()`.
sealed class Result {
  const Result();
}

/// A valid value (after coercion, for `parse()`).
class Valid extends Result {
  const Valid(this.value);

  final Object? value;

  @override
  String toString() => 'Valid($value)';
}

/// An invalid value's errors.
class Invalid extends Result {
  const Invalid(this.errors);

  final List<ValidationError> errors;

  @override
  String toString() => 'Invalid($errors)';
}

/// Compiles `schema` (`true`, `false` or a schema object, as decoded from JSON) into a Validator. The schema is read,
/// never modified.
///
/// - `draft`: 2020-12 by default, or 7.
/// - `formats`: format checks by name. Without one, `format` is an annotation, as 2020-12 specifies.
/// - `schemas`: documents for `$ref`s to other documents, by URI.
/// - `rejectUnresolved`: a `$ref` that names nothing (a missing definition, a document not in `schemas`) throws a
///   SchemaException here by default; with this it compiles as `false` instead, so only values at that place fail,
///   with the error "unresolved reference". Use it for schemas from other systems, whose references may dangle.
Validator compile(
  Object schema, {
  Draft draft = Draft.draft2020,
  Map<String, FormatCheck>? formats,
  Map<String, Object> schemas = const {},
  bool rejectUnresolved = false,
}) {
  final compiler = Compiler(schema, draft, formats, schemas, rejectUnresolved);
  return Validator._(compiler, compiler.root());
}

/// A compiled schema.
class Validator {
  Validator._(this._compiler, this.check);

  final Compiler _compiler;

  /// Whether `value` is valid. A plain function: it may be passed around without its validator.
  final Check check;

  Explainer? _explainer;
  Coercer? _coercer;

  /// Why `value` is invalid: one error per failing keyword, empty when it is valid. Built on the first failure and
  /// kept, so a validator whose values always pass never pays for it.
  List<ValidationError> errors(Object? value) {
    if (check(value)) {
      return const [];
    }

    _explainer ??= Explainer(_compiler);
    return _explainer!.errors(value);
  }

  /// `value` itself when it is valid, else its errors: check() and errors() in one result, without coercion.
  Result validate(Object? value) => check(value) ? Valid(value) : Invalid(errors(value));

  /// `value` coerced towards the schema: numeric strings to numbers, `"true"` to `true`, a single value to a one-item
  /// list, an optional `null` dropped, the first union branch the value converts to (the README lists every rule).
  /// Only the changed paths are copied; `value` comes back itself when nothing changes, and is never modified. Values
  /// that cannot be coerced stay as they are. The rules are built on the first call.
  Object? coerce(Object? value) => (_coercer ??= Coercer(_compiler)).coerce(value);

  /// Coerces `value`, then checks it: the coerced value when it is valid, else its errors.
  Result parse(Object? value) => validate(coerce(value));
}
