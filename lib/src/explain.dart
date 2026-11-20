// Errors of a failed value: a walk over the schema that reports each failing keyword at the value it failed on. It
// runs only for values that failed the check, using the compiler's checks for subschemas.

import 'dart:convert';

import 'annotations.dart';
import 'checks.dart';
import 'compiler.dart';
import 'resolver.dart';
import 'validator.dart';

typedef Errors = List<ValidationError>;

/// Explains failures of one compiled schema.
class Explainer {
  Explainer(this.c);

  final Compiler c;

  /// The errors of `$ref` targets for object and array values, within one errors() call: a recursive union explains
  /// each branch to pick the one to blame, and every branch would explain the same children again, exponentially in
  /// the depth.
  Map<Object?, Map<Object?, ({String path, Errors errors})>>? _memo;

  /// The errors of `value`, at least one (`value` failed the check).
  Errors errors(Object? value) {
    final out = <ValidationError>[];
    try {
      _walk(c.schema, defaultBase, value, '', out);
    } finally {
      _memo = null;
    }

    if (out.isEmpty) {
      out.add(const ValidationError('', 'schema', 'invalid'));
    }

    return out;
  }

  bool _ok(Object? node, String base, Object? v) => c.check(node, base)(v);

  // For $dynamicRef schemas this check runs outside the original dynamic scope, so their errors are approximate.
  void _walk(Object? node, String base, Object? v, String path, Errors out) {
    if (node == true) {
      return;
    }

    if (node == false) {
      out.add(ValidationError(path, 'false', 'no value is allowed here'));
      return;
    }

    if (node is! Map) {
      return;
    }

    final b = c.r.baseFor(node, base);
    if (_ok(node, b, v)) {
      return;
    }

    final start = out.length;

    void push(String keyword, String message, [String? at]) => out.add(ValidationError(at ?? path, keyword, message));

    if (c.draft == Draft.draft7 && node[r'$ref'] is String) {
      _walkRef(node[r'$ref'] as String, b, v, path, out);
      return;
    }

    final type = node['type'];
    if (type != null) {
      final types = type is List ? type : [type];
      if (!types.any((t) => (typeChecks[t] ?? never)(v))) {
        push('type', 'expected ${types.join(' or ')}, got ${_typeName(v)}');
        return;
      }
    }

    if (node['enum'] case final List<Object?> values when !enumCheck(values)(v)) {
      push('enum', 'expected one of ${_listValues(values)}');
    }

    if (node.containsKey('const') && !constCheck(node['const'])(v)) {
      push('const', 'expected ${jsonEncode(node['const'])}');
    }

    switch (v) {
      case String():
        _walkString(node, v, push);
      case num():
        _walkNumber(node, v, push);
      case Map():
        _walkObject(node, b, v, path, out, push);
      case List():
        _walkArray(node, b, v, path, out, push);
    }

    if (node['allOf'] case final List<Object?> all) {
      for (final s in all) {
        _walk(s, b, v, path, out);
      }
    }

    if (node['anyOf'] case final List<Object?> any) {
      _walkUnion(any, b, v, path, out, false);
    }

    if (node['oneOf'] case final List<Object?> one) {
      _walkUnion(one, b, v, path, out, true);
    }

    if (node.containsKey('not') && _ok(node['not'], b, v)) {
      push('not', 'must not match the schema in not');
    }

    if (node.containsKey('if')) {
      final branch = _ok(node['if'], b, v) ? node['then'] : node['else'];
      if (branch != null) {
        _walk(branch, b, v, path, out);
      }
    }

    if (node[r'$ref'] case final String ref) {
      _walkRef(ref, b, v, path, out);
    }

    if (out.length == start && (node.containsKey('unevaluatedProperties') || node.containsKey('unevaluatedItems'))) {
      _walkUnevaluated(node, b, v, path, out);
    }

    if (out.length == start && node[r'$dynamicRef'] is String) {
      push(r'$dynamicRef', 'does not match the dynamically referenced schema');
    }
  }

  void _walkRef(String ref, String base, Object? v, String path, Errors out) {
    final target = c.r.resolve(ref, base);
    if (target.node == false && c.r.isUnresolved(ref, base)) {
      out.add(ValidationError(path, r'$ref', 'unresolved reference $ref'));
      return;
    }

    final node = target.node;
    if (node is! Map || (v is! Map && v is! List)) {
      _walk(node, target.base, v, path, out);
      return;
    }

    final values = (_memo ??= Map.identity()).putIfAbsent(node, Map.identity);
    final known = values[v];
    if (known != null && known.path == path) {
      out.addAll(known.errors);
      return;
    }

    final errors = <ValidationError>[];
    _walk(node, target.base, v, path, errors);
    values[v] = (path: path, errors: errors);
    out.addAll(errors);
  }

  void _walkString(Map<Object?, Object?> node, String v, _Push push) {
    final n = codePoints(v);
    if (node['minLength'] case final num min when n < min) {
      push('minLength', 'expected at least ${_number(min)} characters');
    }

    if (node['maxLength'] case final num max when n > max) {
      push('maxLength', 'expected at most ${_number(max)} characters');
    }

    if (node['pattern'] case final String pattern when !c.regex(pattern).hasMatch(v)) {
      push('pattern', 'expected to match $pattern');
    }

    final format = c.formatOf(node);
    if (format != null && !format(v)) {
      push('format', 'expected format ${node['format']}');
    }
  }

  void _walkNumber(Map<Object?, Object?> node, num v, _Push push) {
    if (node['minimum'] case final num min when v < min) {
      push('minimum', 'expected >= ${_number(min)}');
    }

    if (node['maximum'] case final num max when v > max) {
      push('maximum', 'expected <= ${_number(max)}');
    }

    if (node['exclusiveMinimum'] case final num min when v <= min) {
      push('exclusiveMinimum', 'expected > ${_number(min)}');
    }

    if (node['exclusiveMaximum'] case final num max when v >= max) {
      push('exclusiveMaximum', 'expected < ${_number(max)}');
    }

    if (node['multipleOf'] case final num d when !isMultiple(v, d)) {
      push('multipleOf', 'expected a multiple of ${_number(d)}');
    }
  }

  void _walkObject(Map<Object?, Object?> node, String b, Map<Object?, Object?> v, String path, Errors out, _Push push) {
    final properties = _map(node['properties']);
    for (final k in _list(node['required'])) {
      if (k is String && !v.containsKey(k)) {
        push('required', 'missing', _pointer(path, k));
      }
    }

    for (final MapEntry(:key, :value) in properties.entries) {
      if (v.containsKey(key)) {
        _walk(value, b, v[key], _pointer(path, key), out);
      }
    }

    final patterns = _map(node['patternProperties']);
    final additional = node['additionalProperties'];
    for (final MapEntry(:key, :value) in v.entries) {
      var matched = properties.containsKey(key);
      for (final MapEntry(key: p, value: s) in patterns.entries) {
        if (c.regex(p as String).hasMatch(key as String)) {
          matched = true;
          _walk(s, b, value, _pointer(path, key), out);
        }
      }

      if (!matched && additional != null) {
        if (additional == false) {
          push('additionalProperties', 'unknown field', _pointer(path, key));
        } else {
          _walk(additional, b, value, _pointer(path, key), out);
        }
      }

      if (node.containsKey('propertyNames') && !_ok(node['propertyNames'], b, key)) {
        push('propertyNames', 'invalid property name', _pointer(path, key));
      }
    }

    if (node['minProperties'] case final num min when v.length < min) {
      push('minProperties', 'expected at least ${_number(min)} properties');
    }

    if (node['maxProperties'] case final num max when v.length > max) {
      push('maxProperties', 'expected at most ${_number(max)} properties');
    }

    final dependencies = {
      if (c.draft != Draft.draft7) ..._map(node['dependentRequired']),
      ..._map(node['dependencies']),
    };
    for (final MapEntry(key: k, value: d) in dependencies.entries) {
      if (!v.containsKey(k)) {
        continue;
      }

      if (d is! List) {
        _walk(d, b, v, path, out);
        continue;
      }

      for (final r in d) {
        if (!v.containsKey(r)) {
          push('dependentRequired', 'required when $k is present', _pointer(path, r));
        }
      }
    }

    if (c.draft == Draft.draft7) {
      return;
    }

    for (final MapEntry(:key, :value) in _map(node['dependentSchemas']).entries) {
      if (v.containsKey(key)) {
        _walk(value, b, v, path, out);
      }
    }
  }

  void _walkArray(Map<Object?, Object?> node, String b, List<Object?> v, String path, Errors out, _Push push) {
    var prefix = const <Object?>[];
    Object? rest;
    if (node['items'] case final List<Object?> items) {
      prefix = items;
      rest = node['additionalItems'];
    } else {
      if (c.draft != Draft.draft7 && node['prefixItems'] is List) {
        prefix = node['prefixItems'] as List<Object?>;
      }

      rest = node['items'];
    }

    for (var i = 0; i < v.length; i++) {
      final s = i < prefix.length ? prefix[i] : rest;
      if (s != null) {
        _walk(s, b, v[i], '$path/$i', out);
      }
    }

    if (node['minItems'] case final num min when v.length < min) {
      push('minItems', 'expected at least ${_number(min)} items');
    }

    if (node['maxItems'] case final num max when v.length > max) {
      push('maxItems', 'expected at most ${_number(max)} items');
    }

    if (node['uniqueItems'] == true && !uniqueCheck(v)) {
      push('uniqueItems', 'expected unique items');
    }

    if (node.containsKey('contains')) {
      final (min, max) = c.containsBounds(node);
      if (!containsCheck(c.check(node['contains'], b), min, max)(v)) {
        push('contains', _containsMessage(min, max));
      }
    }
  }

  void _walkUnion(List<Object?> branches, String b, Object? v, String path, Errors out, bool exactlyOne) {
    final matches = branches.where((s) => _ok(s, b, v)).length;
    if (matches == 1) {
      return;
    }

    if (!exactlyOne && matches > 0) {
      return;
    }

    final keyword = exactlyOne ? 'oneOf' : 'anyOf';
    if (matches > 1) {
      out.add(ValidationError(path, keyword, 'matches more than one alternative'));
      return;
    }

    // A tagged union reports the branch its tag selects.
    final tag = _tagOf(branches, b);
    if (tag != null && v is Map) {
      final i = tag.values.indexWhere((x) => deepEqual(x, v[tag.key]));
      if (i < 0) {
        out.add(ValidationError(_pointer(path, tag.key), keyword, 'expected one of ${_listValues(tag.values)}'));
      } else {
        _walk(branches[i], b, v, path, out);
      }

      return;
    }

    // An object is blamed on the branch that declares most of its properties (the one it was most likely meant for),
    // then on the branch whose first error is deepest.
    ({Errors errors, int declared})? best;
    for (final s in branches) {
      final errors = <ValidationError>[];
      _walk(s, b, v, path, errors);
      if (errors.isEmpty) {
        continue;
      }

      final declared = v is Map ? _declaredKeys(s, b, v) : 0;
      if (_better(best, errors, declared)) {
        best = (errors: errors, declared: declared);
      }
    }

    out.addAll(best?.errors ?? [ValidationError(path, keyword, 'matches no alternative')]);
  }

  /// The branch schema `s`, through a `$ref`.
  Object? _resolved(Object? s, String b) {
    if (s is Map && s[r'$ref'] is String) {
      return c.r.resolve(s[r'$ref'] as String, c.r.baseFor(s, b)).node;
    }

    return s;
  }

  /// How many of the keys of `v` the branch `s` declares in `properties`.
  int _declaredKeys(Object? s, String b, Map<Object?, Object?> v) {
    final node = _resolved(s, b);
    return v.keys.where((node is Map ? _map(node['properties']) : const {}).containsKey).length;
  }

  ({String key, List<Object?> values})? _tagOf(List<Object?> branches, String b) {
    final resolved = [for (final s in branches) _resolved(s, b)];
    final first = resolved.first;
    if (first is! Map || first['properties'] is! Map) {
      return null;
    }

    for (final key in (first['properties'] as Map<Object?, Object?>).keys) {
      final values = [for (final s in resolved) _tagValue(s, key)];
      if (values.any((x) => x == _none || x is Map || x is List)) {
        continue;
      }

      if (values.toSet().length == values.length) {
        return (key: key as String, values: values);
      }
    }

    return null;
  }

  void _walkUnevaluated(Map<Object?, Object?> node, String b, Object? v, String path, Errors out) {
    // `b` already applies the node's `$id`; the copy must not apply it again.
    final a = Annotations();
    c.annotating({
      for (final MapEntry(:key, :value) in node.entries)
        if (key != 'unevaluatedProperties' && key != 'unevaluatedItems' && key != r'$id') key: value,
    }, b)(v, a);
    final props = node['unevaluatedProperties'];
    if (v is Map && props != null && !a.allProps) {
      for (final MapEntry(:key, :value) in v.entries) {
        if (a.props.contains(key)) {
          continue;
        }

        if (props == false) {
          out.add(ValidationError(_pointer(path, key), 'unevaluatedProperties', 'unknown field'));
        } else {
          _walk(props, b, value, _pointer(path, key), out);
        }
      }
    }

    final items = node['unevaluatedItems'];
    if (v is List && items != null && !a.allItems) {
      for (var i = a.items; i < v.length; i++) {
        if (a.indexes.contains(i)) {
          continue;
        }

        if (items == false) {
          out.add(ValidationError('$path/$i', 'unevaluatedItems', 'unexpected item'));
        } else {
          _walk(items, b, v[i], '$path/$i', out);
        }
      }
    }
  }
}

typedef _Push = void Function(String keyword, String message, [String? at]);

// A missing tag, told apart from a tag of null.
const _none = Object();

// The primitive const a branch puts on `key`, or _none.
Object? _tagValue(Object? s, Object? key) {
  if (s is! Map) {
    return _none;
  }

  final tag = _map(s['properties'])[key];
  if (tag is! Map || !tag.containsKey('const')) {
    return _none;
  }

  return tag['const'];
}

// Whether a branch with `errors` and `declared` keys is a better one to blame than `best`.
bool _better(({Errors errors, int declared})? best, Errors errors, int declared) {
  if (best == null || declared > best.declared) {
    return true;
  }

  return declared == best.declared && errors[0].path.length > best.errors[0].path.length;
}

// Enum errors name the allowed values; a long list (an enum of thousands) is cut, so the message stays readable.
const _listed = 20;

/// `values` as JSON, at most 20 of them, then how many more there are.
String _listValues(List<Object?> values) {
  if (values.length <= _listed) {
    return jsonEncode(values);
  }

  final listed = jsonEncode(values.sublist(0, _listed));
  return '${listed.substring(0, listed.length - 1)}, ... and ${values.length - _listed} more]';
}

String _containsMessage(num min, num max) {
  if (max == double.infinity) {
    return 'expected at least ${_number(min)} matching ${min == 1 ? 'item' : 'items'}';
  }

  if (min == 0) {
    return 'expected at most ${_number(max)} matching ${max == 1 ? 'item' : 'items'}';
  }

  return 'expected between ${_number(min)} and ${_number(max)} matching items';
}

/// A number as JSON writes it: 2.0 as 2.
String _number(num n) {
  if (n is double && isInteger(n)) {
    return '${n.toInt()}';
  }

  return '$n';
}

String _pointer(String path, Object? key) => '$path/${'$key'.replaceAll('~', '~0').replaceAll('/', '~1')}';

String _typeName(Object? v) {
  return switch (v) {
    null => 'null',
    List() => 'array',
    Map() => 'object',
    num() when !v.isFinite => '$v',
    num() when isInteger(v) => 'integer',
    num() => 'number',
    String() => 'string',
    bool() => 'boolean',
    _ => '${v.runtimeType}',
  };
}

Map<Object?, Object?> _map(Object? value) => value is Map ? value : const {};

List<Object?> _list(Object? value) => value is List ? value : const [];
