// Coercion: turns a loosely typed value (a model's tool call arguments, form input, query strings) into the value a
// schema most likely meant, before it is checked. It is built on a validator's first coerce() or parse(); check()
// never runs it.
//
// Three passes, in this order:
// 1. Optional nulls: a `null` in an optional property whose schema rejects null is dropped, as if omitted.
// 2. Conversion rules ported (through pi-schema) from TypeBox 1.3.27's Value.Convert (MIT), keyed on JSON Schema
//    structure (`$ref`, `const`, `enum`, `anyOf`/`oneOf`, `allOf`, `type`, `items`/`prefixItems`,
//    `properties`/`patternProperties`): `null` becomes "null" for a string, `"3.5"` becomes 3 for an integer, a single
//    value becomes a one-item array, and a union takes the first branch whose conversion passes.
// 3. Primitive coercion by `type` (also type arrays), as in Ajv's `coerceTypes`: what pass 2 left, for example a type
//    array `["integer", "null"]`, or `""` for `null`.
// A value that cannot be coerced is left as it is; the check then reports it.
//
// Every pass is copy-on-write: an object or array is copied only when one of its members changes, so an unchanged
// value comes back as the same object and the input is never modified. A number converted from a string or a boolean
// is an int when it has no fraction, so Dart code can read it as one.

import 'checks.dart';
import 'compiler.dart';
import 'resolver.dart';

/// Coerces values for one compiled schema.
class Coercer {
  Coercer(this.c);

  final Compiler c;

  /// The (schema node, value) pairs pass 2 is converting through a re-entry point. Conversion can enter a node again
  /// with the same value only through a `$ref` or by wrapping a single value into an array: a recursive schema that
  /// meets a value no branch accepts would convert it without end. A pair already entered leaves the value unchanged.
  final _entered = <(Object, Object?)>[];

  /// How often a re-entry was cut short in this coerce() call; results computed across one are not memoized.
  var _cuts = 0;

  /// Results of `$ref` targets by (node, value) within one coerce() call: a recursive union whose branches all convert
  /// the same children (and all fail) would convert them once per branch, exponentially in the depth.
  Map<Object, Map<Object?, Object?>>? _memo;

  /// `value` coerced: a copy along the changed paths only, or `value` itself when nothing changes.
  Object? coerce(Object? value) {
    return _coerceTypes(convert(_dropOptionalNulls(value, c.schema, defaultBase)), c.schema, defaultBase);
  }

  /// Pass 2 alone, as TypeBox's `Value.Convert` (its conformance tests run it).
  Object? convert(Object? value) {
    try {
      return _convert(c.schema, defaultBase, value);
    } finally {
      _memo = null;
      _cuts = 0;
    }
  }

  /// `node` converted for `value` at a re-entry point: unchanged when that pair is already being converted.
  Object? _reenter(Object node, String base, Object? value, bool memoize) {
    if (_entered.any((e) => identical(e.$1, node) && identical(e.$2, value))) {
      _cuts++;
      return value;
    }

    final memo = _memo?[node];
    if (memoize && memo != null && memo.containsKey(value)) {
      return memo[value];
    }

    final cuts = _cuts;
    _entered.add((node, value));
    final Object? result;
    try {
      result = _convert(node, base, value);
    } finally {
      _entered.removeLast();
    }

    if (memoize && _cuts == cuts) {
      (_memo ??= Map.identity()).putIfAbsent(node, Map.identity)[value] = result;
    }

    return result;
  }

  /// Whether `value` passes the schema `node`; null when `node` cannot be compiled.
  bool? _passes(Object? node, String base, Object? value) {
    try {
      return c.check(node, _baseOf(node, base))(value);
    } on Exception {
      return null;
    }
  }

  String _baseOf(Object? node, String base) => node is Map<Object?, Object?> ? c.r.baseFor(node, base) : base;

  // Pass 1: optional nulls.

  Object? _dropOptionalNulls(Object? value, Object? schema, String base) {
    if (schema is! Map<Object?, Object?>) {
      return value;
    }

    final b = _baseOf(schema, base);
    if (value is List<Object?>) {
      return _mapItems(value, (item, i) {
        final s = _itemSchemaAt(schema, i);
        return s == null ? item : _dropOptionalNulls(item, s, b);
      });
    }

    if (value is! Map<Object?, Object?>) {
      return value;
    }

    final properties = _map(schema['properties']);
    final patterns = _patterns(schema);
    final additional = _schemaObject(schema['additionalProperties']);
    if (patterns.isEmpty && additional == null && schema['properties'] is! Map) {
      return value;
    }

    final required = _list(schema['required']).toSet();
    final out = _Copy(value);
    for (final MapEntry(:key, value: property) in properties.entries) {
      if (!value.containsKey(key)) {
        continue;
      }
      if (value[key] == null &&
          !required.contains(key) &&
          !(property is Map && property[r'$ref'] is String) &&
          _passes(property, b, null) == false) {
        out.remove(key);
        continue;
      }

      out[key] = _dropOptionalNulls(value[key], property, b);
    }

    // Values of pattern and additional properties are walked for their own optional nulls; the keys themselves are
    // not optional properties, so they stay.
    if (patterns.isEmpty && additional == null) {
      return out.result;
    }

    for (final key in value.keys) {
      var matched = properties.containsKey(key);
      for (final (re, item) in patterns) {
        if (re.hasMatch(key as String)) {
          matched = true;
          out[key] = _dropOptionalNulls(out.current[key], item, b);
        }
      }

      if (!matched && additional != null) {
        out[key] = _dropOptionalNulls(value[key], additional, b);
      }
    }

    return out.result;
  }

  // Pass 2: TypeBox's conversion rules.

  Object? _convert(Object? node, String base, Object? value) {
    if (node is! Map<Object?, Object?>) {
      return value;
    }

    final b = _baseOf(node, base);
    if (node[r'$ref'] case final String ref) {
      final Resolved target;
      try {
        target = c.r.resolve(ref, b);
      } on Exception {
        return value;
      }

      final n = target.node;
      return n is Map<Object?, Object?> ? _reenter(n, target.base, value, true) : value;
    }

    return _convertNode(node, b, value);
  }

  /// One schema node's conversion: its first keyword among `const`, `enum`, the unions, `allOf` and `type`.
  Object? _convertNode(Map<Object?, Object?> node, String b, Object? value) {
    if (node.containsKey('const')) {
      return _convertLiteral(node['const'], value);
    }

    if (node['enum'] case final List<Object?> values) {
      return _convertEnum(node, values, b, value);
    }

    // A union or intersection node may also declare members: they convert after the branches.
    if (node['anyOf'] case final List<Object?> branches) {
      return _convertUnion(node, branches, b, value);
    }

    if (node['oneOf'] case final List<Object?> branches) {
      return _convertUnion(node, branches, b, value);
    }

    if (node['allOf'] case final List<Object?> members) {
      var next = value;
      for (final member in members) {
        next = _convert(member, b, next);
      }

      return _convertMembers(node, b, next);
    }

    switch (node['type']) {
      case 'string':
        return _tryString(value) ?? value;
      case 'number':
        return _tryNumber(value) ?? value;
      case 'integer':
        final n = _tryNumber(value);
        return n == null ? value : _truncate(n);
      case 'boolean':
        return _tryBoolean(value) ?? value;
      case 'null':
        return _tryNull(value) ? null : value;
      case 'array':
        return _convertArray(node, b, value);
      case 'object':
        return _convertObject(node, b, value);
      case null:
        if (node.containsKey('properties') || node.containsKey('patternProperties')) {
          return _convertObject(node, b, value);
        }

        if (node.containsKey('items') || node.containsKey('prefixItems')) {
          return _convertArray(node, b, value);
        }

        return value;
      default:
        return value;
    }
  }

  /// An enum is a union of its values: a member stays, else the first value the input converts to.
  Object? _convertEnum(Map<Object?, Object?> node, List<Object?> values, String base, Object? value) {
    if (values.any((member) => _strictEqual(member, value))) {
      return value;
    }

    for (final member in values) {
      final candidate = _convertLiteral(member, value);
      if (!identical(candidate, value) && _passes(node, base, candidate) == true) {
        return candidate;
      }
    }

    return value;
  }

  /// A value one branch accepts stays; else the first branch's conversion that the whole union accepts. Branches are
  /// converted in order and only until one is accepted, so a later recursive branch is not entered needlessly. A node
  /// that also declares members converts them into each candidate before it is checked, so a branch is not discarded
  /// for a sibling property that is converted after it.
  Object? _convertUnion(Map<Object?, Object?> node, List<Object?> branches, String base, Object? value) {
    if (branches.any((branch) => _passes(branch, base, value) == true)) {
      return _convertMembers(node, base, value);
    }

    for (final branch in branches) {
      final candidate = _convertMembers(node, base, _convert(branch, base, value));
      if (_passes(node, base, candidate) == true) {
        return candidate;
      }
    }

    return _convertMembers(node, base, value);
  }

  /// The object members of a union or intersection node, when it declares any.
  Object? _convertMembers(Map<Object?, Object?> node, String base, Object? value) {
    if (node.containsKey('properties') ||
        node.containsKey('patternProperties') ||
        node.containsKey('additionalProperties')) {
      return _convertObject(node, base, value);
    }

    return value;
  }

  Object? _convertArray(Map<Object?, Object?> node, String base, Object? value) {
    final items = node['items'];
    final prefix = switch (items) {
      final List<Object?> list => list,
      _ => node['prefixItems'] is List ? node['prefixItems'] as List<Object?> : null,
    };
    if (prefix != null) {
      // A tuple converts its items and never wraps a single value.
      if (value is! List<Object?>) {
        return value;
      }

      final rest = items is List ? null : items;
      return _mapItems(value, (item, i) {
        final s = i < prefix.length ? prefix[i] : rest;
        return s == null ? item : _convert(s, base, item);
      });
    }

    if (value is List<Object?>) {
      return items == null ? value : _mapItems(value, (item, i) => _convert(items, base, item));
    }

    // The wrapped single value is converted by the item schema with the same value: a re-entry point.
    return [items is Map<Object?, Object?> ? _reenter(items, base, value, false) : value];
  }

  Object? _convertObject(Map<Object?, Object?> node, String base, Object? value) {
    if (value is! Map<Object?, Object?>) {
      return value;
    }

    final properties = _map(node['properties']);
    final patterns = _patterns(node);
    final additional = _schemaObject(node['additionalProperties']);
    final out = _Copy(value);
    for (final MapEntry(:key, value: v) in value.entries) {
      var next = v;
      var matched = properties.containsKey(key);
      if (matched) {
        next = _convert(properties[key], base, next);
      }

      for (final (re, s) in patterns) {
        if (re.hasMatch(key as String)) {
          matched = true;
          next = _convert(s, base, next);
        }
      }

      if (!matched && additional != null) {
        next = _convert(additional, base, next);
      }

      out[key] = next;
    }

    return out.result;
  }

  // Pass 3: primitive coercion by type.

  Object? _coerceTypes(Object? value, Object? schema, String base) {
    if (schema is! Map<Object?, Object?>) {
      return value;
    }

    final b = _baseOf(schema, base);
    var next = value;
    for (final member in _list(schema['allOf'])) {
      next = _coerceTypes(next, member, b);
    }

    if (schema['anyOf'] case final List<Object?> branches) {
      next = _coerceUnion(next, branches, b);
    }

    if (schema['oneOf'] case final List<Object?> branches) {
      next = _coerceUnion(next, branches, b);
    }

    final types = _typesOf(schema);

    // A value that already has one of a type array's types stays.

    if (!(types.length > 1 && types.any((type) => (typeChecks[type] ?? never)(next)))) {
      for (final type in types) {
        final candidate = _coercePrimitive(next, type);
        if (!identical(candidate, next)) {
          next = candidate;
          break;
        }
      }
    }

    if (types.contains('object') && next is Map<Object?, Object?>) {
      next = _coerceProperties(next, schema, b);
    }

    if (types.contains('array') && next is List<Object?>) {
      next = _mapItems(next, (item, i) {
        final s = _itemSchemaAt(schema, i);
        return s is Map ? _coerceTypes(item, s, b) : item;
      });
    }

    return next;
  }

  Object? _coerceUnion(Object? value, List<Object?> branches, String base) {
    if (branches.any((branch) => _passes(branch, base, value) == true)) {
      return value;
    }

    for (final branch in branches) {
      final coerced = _coerceTypes(value, branch, base);
      if (_passes(branch, base, coerced) == true) {
        return coerced;
      }
    }

    return value;
  }

  Object? _coerceProperties(Map<Object?, Object?> value, Map<Object?, Object?> schema, String base) {
    final properties = _map(schema['properties']);
    final patterns = _patterns(schema);
    final additional = _schemaObject(schema['additionalProperties']);
    final out = _Copy(value);
    for (final MapEntry(:key, value: property) in properties.entries) {
      if (value.containsKey(key)) {
        out[key] = _coerceTypes(value[key], property, base);
      }
    }

    for (final key in value.keys) {
      var matched = properties.containsKey(key);
      for (final (re, item) in patterns) {
        if (re.hasMatch(key as String)) {
          matched = true;
          out[key] = _coerceTypes(out.current[key], item, base);
        }
      }

      if (!matched && additional != null) {
        out[key] = _coerceTypes(value[key], additional, base);
      }
    }

    return out.result;
  }

  List<(RegExp, Object?)> _patterns(Map<Object?, Object?> schema) {
    return [
      for (final MapEntry(:key, :value) in _map(schema['patternProperties']).entries) (c.regex(key as String), value),
    ];
  }
}

/// A copy-on-write map: the original until a member changes, then a copy.
class _Copy {
  _Copy(this._original);

  final Map<Object?, Object?> _original;
  Map<Object?, Object?>? _copy;

  Map<Object?, Object?> get current => _copy ?? _original;

  Map<Object?, Object?> get result => current;

  void operator []=(Object? key, Object? value) {
    if (identical(current[key], value) && current.containsKey(key)) {
      return;
    }

    (_copy ??= Map.of(_original))[key] = value;
  }

  void remove(Object? key) => (_copy ??= Map.of(_original)).remove(key);
}

/// The schema of an array's item at `index`: a tuple's (`prefixItems`, or a draft-7 `items` array) for its prefix,
/// `items` after `prefixItems`, or `items` for every item. Null when nothing applies.
Object? _itemSchemaAt(Map<Object?, Object?> schema, int index) {
  final items = schema['items'];
  if (items is List) {
    return index < items.length ? items[index] : null;
  }

  final prefix = schema['prefixItems'];
  if (prefix is List && index < prefix.length) {
    return prefix[index];
  }

  return items;
}

/// `items` mapped by `map`; the same list when every item maps to itself.
List<Object?> _mapItems(List<Object?> items, Object? Function(Object? item, int index) map) {
  List<Object?>? out;
  for (var i = 0; i < items.length; i++) {
    final next = map(items[i], i);
    if (!identical(next, items[i])) {
      (out ??= List.of(items))[i] = next;
    }
  }

  return out ?? items;
}

// TypeBox's conversions of one value (value/convert/try in TypeBox 1.3.27): a result, or null when there is none.

/// Primitives as JavaScript's `===` compares them: a number equals a number of the same value, nothing else is equal
/// across types.
bool _strictEqual(Object? a, Object? b) {
  if (a is num && b is num) {
    return a == b;
  }

  if (a is String || a is bool || a == null) {
    return a == b;
  }

  return identical(a, b);
}

/// A literal (`const`, an enum value) taken from a value of another type that converts to exactly it.
Object? _convertLiteral(Object? literal, Object? value) {
  if (_strictEqual(literal, value)) {
    return value;
  }

  final Object? result = switch (literal) {
    String() => _tryString(value),
    num() => _tryNumber(value),
    bool() => _tryBoolean(value),
    _ => null,
  };
  if (result != null && _strictEqual(result, literal)) {
    return literal;
  }

  return value;
}

String? _tryString(Object? value) {
  return switch (value) {
    bool() => '$value',
    num() when value.isFinite => _text(value),
    null => 'null',
    String() => value,
    _ => null,
  };
}

/// A number as JavaScript writes it: 2.0 as 2.
String _text(num n) {
  if (n is double && isInteger(n)) {
    return '${n.toInt()}';
  }

  return '$n';
}

num? _tryNumber(Object? value) {
  switch (value) {
    case bool():
      return value ? 1 : 0;
    case num() when value.isFinite:
      return value;
    case null:
      return 0;
    case String():
      final n = _jsNumber(value);
      if (n != null && n.isFinite) {
        return n;
      }

      final lowercase = value.toLowerCase();
      if (lowercase == 'false') {
        return 0;
      }

      if (lowercase == 'true') {
        return 1;
      }

      return _integerOfString(value);
    default:
      return null;
  }
}

/// TypeBox's TryBigInt of a string, kept within safe integers: `12n`, `12.5` (truncated) or `12`.
int? _integerOfString(String value) {
  final match = RegExp(r'^(-?(?:0|[1-9]\d*))(?:n|\.\d+)?$').firstMatch(value);
  if (match == null) {
    return null;
  }

  final n = BigInt.parse(match[1]!);
  if (n.abs() > BigInt.from(_maxSafe)) {
    return null;
  }

  return n.toInt();
}

const _maxSafe = 9007199254740991;

bool? _tryBoolean(Object? value) {
  switch (value) {
    case bool():
      return value;
    case num() when value.isFinite:
      return switch (value) {
        0 => false,
        1 => true,
        _ => null,
      };
    case null:
      return false;
    case String():
      final lowercase = value.toLowerCase();
      if (lowercase == 'false' || value == '0') {
        return false;
      }

      if (lowercase == 'true' || value == '1') {
        return true;
      }

      return null;
    default:
      return null;
  }
}

/// Whether `value` converts to null: false, 0, null, `"undefined"`, `"null"`, `""` and `"0"`.
bool _tryNull(Object? value) {
  return switch (value) {
    false || null => true,
    num() when value.isFinite => value == 0,
    String() => const {'undefined', 'null', '', '0'}.contains(value.toLowerCase()),
    _ => false,
  };
}

/// JavaScript's `Number(string)`: surrounding whitespace ignored, `""` is 0, decimal, exponent, `Infinity` and
/// `0x`/`0o`/`0b` integers; null for anything else (NaN). A whole number comes back as an int.
num? _jsNumber(String value) {
  final s = value.trim();
  if (s.isEmpty) {
    return 0;
  }

  final radix = RegExp(r'^0([xXoObB])([0-9a-fA-F]+)$').firstMatch(s);
  if (radix != null) {
    final n = BigInt.tryParse(
      radix[2]!,
      radix: switch (radix[1]!.toLowerCase()) {
        'x' => 16,
        'o' => 8,
        _ => 2,
      },
    );
    return n == null ? null : _whole(n.toDouble());
  }

  if (RegExp(r'^[+-]?Infinity$').hasMatch(s)) {
    return s.startsWith('-') ? double.negativeInfinity : double.infinity;
  }

  if (!RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$').hasMatch(s)) {
    return null;
  }

  return _whole(double.parse(s));
}

/// `n` without its fraction, as an int when it is within the safe integers.
num _truncate(num n) {
  if (n is int) {
    return n;
  }

  return _whole(n.truncateToDouble());
}

/// `n` as an int when it is a whole number within the safe integers, else as it is.
num _whole(double n) {
  if (!isInteger(n)) {
    return n;
  }

  if (n.abs() > _maxSafe) {
    return n;
  }

  return n.toInt();
}

List<String> _typesOf(Map<Object?, Object?> schema) {
  return switch (schema['type']) {
    final String type => [type],
    final List<Object?> types => types.whereType<String>().toList(),
    _ => const [],
  };
}

Object? _coercePrimitive(Object? value, String type) {
  switch (type) {
    case 'number' || 'integer':
      if (value == null) {
        return 0;
      }

      if (value is String && value.trim().isNotEmpty) {
        final n = _jsNumber(value);
        if (n != null && (type == 'number' ? isNumber(n) : isInteger(n))) {
          return n;
        }
      }

      if (value is bool) {
        return value ? 1 : 0;
      }

      return value;
    case 'boolean':
      return switch (value) {
        null || 'false' || 0 => false,
        'true' || 1 => true,
        _ => value,
      };
    case 'string':
      return switch (value) {
        null => '',
        num() || bool() => _tryString(value),
        _ => value,
      };
    case 'null':
      return switch (value) {
        '' || 0 || false => null,
        _ => value,
      };
    default:
      return value;
  }
}

Map<Object?, Object?> _map(Object? value) => value is Map<Object?, Object?> ? value : const {};

List<Object?> _list(Object? value) => value is List<Object?> ? value : const [];

Map<Object?, Object?>? _schemaObject(Object? value) => value is Map<Object?, Object?> ? value : null;
