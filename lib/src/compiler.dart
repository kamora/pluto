// The compiler: a schema to one check closure, built once. Keywords group by the type they constrain, so a value is
// classified once per keyword group.

import 'annotations.dart';
import 'checks.dart';
import 'resolver.dart';
import 'validator.dart';

/// One compile of a schema. Its caches and indexes are garbage once the root check is built, unless the schema has a
/// `$dynamicRef` that resolves at run time.
class Compiler {
  Compiler(this.schema, this.draft, this.formats, Map<String, Object> schemas, bool reject)
    : r = Resolver(schema, draft, schemas, reject);

  final Object schema;
  final Draft draft;
  final Resolver r;

  /// Format checks by name; a format without one is an annotation.
  final Map<String, bool Function(String)>? formats;

  /// The dynamic scope: the base URIs of the schema resources entered, outermost first.
  final _scope = <String>[];

  final _cache = Map<Object, Check>.identity();
  final _annotatingCache = Map<Object, AnnotatingCheck>.identity();
  final _regexes = <String, RegExp>{};

  /// The check of the root schema.
  Check root() => check(schema, defaultBase);

  /// The check of a schema (cached by schema object; a recursive reference goes through an indirection).
  Check check(Object? node, String base) {
    if (node == true) {
      return always;
    }

    if (node == false) {
      return never;
    }

    if (node is! Map) {
      throw SchemaException('A schema must be an object or a boolean, got $node');
    }

    final cached = _cache[node];
    if (cached != null) {
      return cached;
    }

    final slot = Slot<Check>();
    _cache[node] = (v) => slot.check(v);
    final check = _build(node, r.baseFor(node, base));
    slot.check = check;
    _cache[node] = check;
    return check;
  }

  /// The regular expression of a `pattern`: ECMAScript with Unicode; a source that is invalid with it (some older
  /// schemas escape characters Unicode mode rejects) compiles without it.
  RegExp regex(String source) {
    return _regexes.putIfAbsent(source, () {
      try {
        return RegExp(source, unicode: true);
      } on FormatException {
        return RegExp(source);
      }
    });
  }

  /// The format check of `node`, null when formats are not checked or the format is unknown.
  bool Function(String)? formatOf(Map<Object?, Object?> node) {
    final format = node['format'];
    if (format is! String) {
      return null;
    }

    return formats?[format];
  }

  Check _build(Map<Object?, Object?> node, String base) {
    if (draft == Draft.draft7 && node[r'$ref'] is String) {
      return _ref(node[r'$ref'] as String, base);
    }

    if (draft != Draft.draft7 && (node.containsKey('unevaluatedProperties') || node.containsKey('unevaluatedItems'))) {
      return withFreshAnnotations(annotating(node, base));
    }

    final check = _plain(node, base);
    return r.isResource(node, base) ? scopedCheck(_scope, base, check) : check;
  }

  /// Every keyword of `node`, not tracking annotations.
  Check _plain(Map<Object?, Object?> node, String base) {
    final parts = <Check>[];
    final type = node['type'];
    final types = switch (type) {
      null => null,
      List() => type,
      _ => [type],
    };
    final single = types?.length == 1 ? types![0] : null;
    final string = _stringGroup(node, single == 'string');
    final number = _numberGroup(node, single == 'number' || single == 'integer', single == 'integer');
    final object = _objectGroup(node, base, single == 'object');
    final array = _arrayGroup(node, base, single == 'array');
    parts.addAll([?string, ?number, ?object, ?array]);

    // A single type is checked by its group when it has one.
    if (types != null &&
        !switch (single) {
          'string' => string != null,
          'number' || 'integer' => number != null,
          'object' => object != null,
          'array' => array != null,
          _ => false,
        }) {
      parts.insert(0, typeCheck(types));
    }

    _inPlace(node, base, parts);
    return and(parts);
  }

  // The keywords that apply to the value itself, whatever its type.
  void _inPlace(Map<Object?, Object?> node, String base, List<Check> parts) {
    if (node['enum'] case final List<Object?> values) {
      parts.add(enumCheck(values));
    }

    if (node.containsKey('const')) {
      parts.add(constCheck(node['const']));
    }

    if (node['allOf'] case final List<Object?> all) {
      parts.add(and([for (final s in all) check(s, base)]));
    }

    if (node['anyOf'] case final List<Object?> any) {
      parts.add(anyCheck([for (final s in any) check(s, base)]));
    }

    if (node['oneOf'] case final List<Object?> one) {
      parts.add(oneCheck([for (final s in one) check(s, base)]));
    }

    if (node.containsKey('not')) {
      parts.add(notCheck(check(node['not'], base)));
    }

    if (node.containsKey('if') && (node.containsKey('then') || node.containsKey('else'))) {
      parts.add(
        ifCheck(
          check(node['if'], base),
          node.containsKey('then') ? check(node['then'], base) : always,
          node.containsKey('else') ? check(node['else'], base) : always,
        ),
      );
    }

    if (node[r'$ref'] case final String ref) {
      parts.add(_ref(ref, base));
    }

    if (draft == Draft.draft7) {
      return;
    }

    if (node[r'$dynamicRef'] case final String ref) {
      parts.add(_dynamicRef(ref, base));
    }
  }

  Check _ref(String ref, String base) {
    final target = r.resolve(ref, base);
    final check = this.check(target.node, target.base);
    return target.base != base ? scopedCheck(_scope, target.base, check) : check;
  }

  Check _dynamicRef(String ref, String base) {
    final resolved = bookended(ref, base);
    if (resolved == null) {
      return _ref(ref, base);
    }

    final fallback = check(resolved.initial.node, resolved.initial.base);
    final lookup = _dynamicLookup(resolved.name, check);
    final scope = _scope;
    return (v) {
      for (final uri in scope) {
        final check = lookup(uri);
        if (check != null) {
          return check(v);
        }
      }

      return fallback(v);
    };
  }

  /// The initial target and anchor name of a `$dynamicRef` that resolves dynamically, or null for a plain reference.
  ({Resolved initial, String name})? bookended(String ref, String base) {
    final initial = r.resolve(ref, base);
    final uri = resolveUri(ref, base);
    final name = uri.substring(documentOf(uri).length).replaceFirst('#', '');
    if (name.isEmpty || name.startsWith('/')) {
      return null;
    }

    final node = initial.node;
    if (node is! Map || node[r'$dynamicAnchor'] != name) {
      return null;
    }

    return (initial: initial, name: name);
  }

  // Resolved at run time against the dynamic scope.
  T? Function(String uri) _dynamicLookup<T extends Object>(String name, T Function(Object node, String base) compile) {
    final found = <String, T?>{};
    return (uri) {
      final key = '$uri#$name';
      return found.putIfAbsent(key, () {
        final target = r.dynamicAnchors[key];
        return target == null ? null : compile(target, r.baseOf[target] ?? uri);
      });
    };
  }

  Check? _stringGroup(Map<Object?, Object?> node, bool strict) {
    final min = _num(node['minLength']) ?? 0;
    final max = _num(node['maxLength']) ?? double.infinity;
    final pattern = node['pattern'];
    final re = pattern is String ? regex(pattern) : null;
    final format = formatOf(node);
    if (min == 0 && max == double.infinity && re == null && format == null) {
      return null;
    }

    return stringCheck(strict, min, max, re, format);
  }

  Check? _numberGroup(Map<Object?, Object?> node, bool strict, bool integer) {
    final min = _num(node['minimum']);
    final max = _num(node['maximum']);
    final xmin = _num(node['exclusiveMinimum']);
    final xmax = _num(node['exclusiveMaximum']);
    final multipleOf = _num(node['multipleOf']);
    if ([min, max, xmin, xmax, multipleOf].every((x) => x == null)) {
      return null;
    }

    const inf = double.infinity;
    return numberCheck(strict, integer, min ?? -inf, max ?? inf, xmin ?? -inf, xmax ?? inf, multipleOf);
  }

  Check? _objectGroup(Map<Object?, Object?> node, String base, bool strict) {
    final parts = <Check>[];
    final properties = _map(node['properties']);
    final required = [
      for (final k in _list(node['required']))
        if (k is String) k,
    ];
    final patterns = _map(node['patternProperties']);
    final additional = node['additionalProperties'];

    // `additionalProperties` that is absent or true allows every other property.
    final open = additional == null || additional == true;
    if (properties.isNotEmpty || required.isNotEmpty || patterns.isNotEmpty || !open) {
      parts.add(
        propertiesCheck(
          {for (final MapEntry(:key, :value) in properties.entries) key as String: check(value, base)},
          required,
          [for (final MapEntry(:key, :value) in patterns.entries) (regex(key as String), check(value, base))],
          open ? null : check(additional, base),
        ),
      );
    }

    if (node.containsKey('propertyNames')) {
      parts.add(propertyNamesCheck(check(node['propertyNames'], base)));
    }

    final minProperties = _num(node['minProperties']);
    final maxProperties = _num(node['maxProperties']);
    if (minProperties != null || maxProperties != null) {
      parts.add(propertyCountCheck(minProperties ?? 0, maxProperties ?? double.infinity));
    }

    final dependentRequired = <(String, List<Object?>)>[];
    final dependentSchemas = <(String, Check)>[];
    if (draft != Draft.draft7) {
      for (final MapEntry(:key, :value) in _map(node['dependentRequired']).entries) {
        if (value is List) {
          dependentRequired.add((key as String, value));
        }
      }

      for (final MapEntry(:key, :value) in _map(node['dependentSchemas']).entries) {
        dependentSchemas.add((key as String, check(value, base)));
      }
    }

    for (final MapEntry(:key, :value) in _map(node['dependencies']).entries) {
      if (value is List) {
        dependentRequired.add((key as String, value));
      } else {
        dependentSchemas.add((key as String, check(value, base)));
      }
    }

    if (dependentRequired.isNotEmpty) {
      parts.add(dependentRequiredCheck(dependentRequired));
    }

    if (dependentSchemas.isNotEmpty) {
      parts.add(dependentSchemasCheck(dependentSchemas));
    }

    if (parts.isEmpty) {
      return strict ? isObject : null;
    }

    return guardObject(and(parts), strict);
  }

  Check? _arrayGroup(Map<Object?, Object?> node, String base, bool strict) {
    var prefix = const <Object?>[];
    Object? rest;
    if (node['items'] case final List<Object?> items) {
      prefix = items;
      rest = node['additionalItems'];
    } else {
      if (draft != Draft.draft7 && node['prefixItems'] is List) {
        prefix = node['prefixItems'] as List<Object?>;
      }

      rest = node['items'];
    }

    final parts = <Check>[];
    if (prefix.isNotEmpty || (rest != null && rest != true)) {
      parts.add(itemsCheck([for (final s in prefix) check(s, base)], rest == null ? null : check(rest, base)));
    }

    final minItems = _num(node['minItems']);
    final maxItems = _num(node['maxItems']);
    if (minItems != null || maxItems != null) {
      parts.add(lengthCheck(minItems ?? 0, maxItems ?? double.infinity));
    }

    if (node.containsKey('contains')) {
      final (min, max) = containsBounds(node);
      parts.add(containsCheck(check(node['contains'], base), min, max));
    }

    if (node['uniqueItems'] == true) {
      parts.add(uniqueCheck);
    }

    if (parts.isEmpty) {
      return strict ? isArray : null;
    }

    return guardArray(and(parts), strict);
  }

  /// The bounds of `contains`: `minContains` and `maxContains` (only since 2020-12).
  (num, num) containsBounds(Map<Object?, Object?> node) {
    if (draft == Draft.draft7) {
      return (1, double.infinity);
    }

    return (_num(node['minContains']) ?? 1, _num(node['maxContains']) ?? double.infinity);
  }

  /// The annotating check of a schema evaluated in place (only below `unevaluatedProperties`/`unevaluatedItems`).
  AnnotatingCheck annotating(Object? node, String base) {
    if (node == true) {
      return annotatingTrue;
    }

    if (node == false) {
      return annotatingFalse;
    }

    if (node is! Map) {
      throw SchemaException('A schema must be an object or a boolean, got $node');
    }

    final cached = _annotatingCache[node];
    if (cached != null) {
      return cached;
    }

    final slot = Slot<AnnotatingCheck>();
    _annotatingCache[node] = (v, a) => slot.check(v, a);
    final check = _buildAnnotating(node, r.baseFor(node, base));
    slot.check = check;
    _annotatingCache[node] = check;
    return check;
  }

  AnnotatingCheck _buildAnnotating(Map<Object?, Object?> node, String base) {
    final plain = _plain({
      for (final MapEntry(:key, :value) in node.entries)
        if (!_annotatingKeywords.contains(key)) key: value,
    }, base);
    final parts = <AnnotatingCheck>[];
    if (node.keys.any(_annotatingKeywords.contains)) {
      _annotatingParts(node, base, parts);
    }

    final all = parts.isEmpty ? ignoreAnnotations(plain) : annotateAll(plain, parts);
    final own = node.containsKey('unevaluatedProperties') || node.containsKey('unevaluatedItems')
        ? isolateAnnotations(all)
        : all;
    return r.isResource(node, base) ? scopedAnnotating(_scope, base, own) : own;
  }

  void _annotatingParts(Map<Object?, Object?> node, String base, List<AnnotatingCheck> parts) {
    if (node.containsKey('properties') ||
        node.containsKey('patternProperties') ||
        node.containsKey('additionalProperties')) {
      parts.add(
        annotateObject(
          {for (final MapEntry(:key, :value) in _map(node['properties']).entries) key as String: check(value, base)},
          [
            for (final MapEntry(:key, :value) in _map(node['patternProperties']).entries)
              (regex(key as String), check(value, base)),
          ],
          node.containsKey('additionalProperties') ? check(node['additionalProperties'], base) : null,
        ),
      );
    }

    if (node.containsKey('prefixItems') || node.containsKey('items') || node.containsKey('contains')) {
      final items = node['items'];
      final rest = items is List ? node['additionalItems'] : items;
      final (min, max) = containsBounds(node);
      parts.add(
        annotateArray(
          [
            for (final s in switch (node['prefixItems']) {
              final List<Object?> list => list,
              _ => items is List ? items : const [],
            })
              check(s, base),
          ],
          rest == null ? null : check(rest, base),
          node.containsKey('contains') ? check(node['contains'], base) : null,
          min,
          max,
        ),
      );
    }

    if (node['allOf'] case final List<Object?> all) {
      for (final s in all) {
        parts.add(annotating(s, base));
      }
    }

    if (node['anyOf'] case final List<Object?> any) {
      parts.add(annotateAny([for (final s in any) annotating(s, base)], false));
    }

    if (node['oneOf'] case final List<Object?> one) {
      parts.add(annotateAny([for (final s in one) annotating(s, base)], true));
    }

    if (node.containsKey('if')) {
      parts.add(
        annotateIf(
          annotating(node['if'], base),
          node.containsKey('then') ? annotating(node['then'], base) : null,
          node.containsKey('else') ? annotating(node['else'], base) : null,
        ),
      );
    }

    if (node[r'$ref'] case final String ref) {
      parts.add(_annotatingRef(ref, base));
    }

    if (node[r'$dynamicRef'] case final String ref) {
      parts.add(_annotatingDynamicRef(ref, base));
    }

    for (final MapEntry(:key, :value) in _map(node['dependentSchemas']).entries) {
      parts.add(annotateDependent(key as String, annotating(value, base)));
    }

    if (node.containsKey('unevaluatedProperties')) {
      parts.add(unevaluatedProperties(check(node['unevaluatedProperties'], base)));
    }

    if (node.containsKey('unevaluatedItems')) {
      parts.add(unevaluatedItems(check(node['unevaluatedItems'], base)));
    }
  }

  AnnotatingCheck _annotatingRef(String ref, String base) {
    final target = r.resolve(ref, base);
    final check = annotating(target.node, target.base);
    return target.base != base ? scopedAnnotating(_scope, target.base, check) : check;
  }

  AnnotatingCheck _annotatingDynamicRef(String ref, String base) {
    final resolved = bookended(ref, base);
    if (resolved == null) {
      return _annotatingRef(ref, base);
    }

    final fallback = annotating(resolved.initial.node, resolved.initial.base);
    final lookup = _dynamicLookup(resolved.name, annotating);
    final scope = _scope;
    return (v, a) {
      for (final uri in scope) {
        final check = lookup(uri);
        if (check != null) {
          return check(v, a);
        }
      }

      return fallback(v, a);
    };
  }
}

// The keywords an annotating check handles itself; every other keyword compiles into its plain part.
const _annotatingKeywords = {
  'properties',
  'patternProperties',
  'additionalProperties',
  'prefixItems',
  'items',
  'additionalItems',
  'contains',
  'minContains',
  'maxContains',
  'allOf',
  'anyOf',
  'oneOf',
  'if',
  'then',
  'else',
  r'$ref',
  r'$dynamicRef',
  'dependentSchemas',
  'unevaluatedProperties',
  'unevaluatedItems',
};

num? _num(Object? value) => value is num ? value : null;

Map<Object?, Object?> _map(Object? value) => value is Map ? value : const {};

List<Object?> _list(Object? value) => value is List ? value : const [];
