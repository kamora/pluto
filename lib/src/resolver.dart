// Reference resolution of one compile: schema resources, anchors and JSON Pointers over the root schema and the
// registered documents. A Resolver lives only while a schema compiles (or while its errors are explained).

import 'validator.dart';

/// A schema and the base URI its references resolve against.
typedef Resolved = ({Object? node, String base});

/// The base URI of a root schema without `$id`; relative references resolve against it.
const defaultBase = 'https://json-schema.invalid/root.json';

/// Resolves references in the root schema and the registered documents. The schema is indexed on the first reference
/// or the first `$id` a walker meets, so a schema with neither is never walked for identifiers.
class Resolver {
  Resolver(this.root, this.draft, this.schemas, this.reject);

  final Object root;
  final Draft draft;
  final Map<String, Object> schemas;

  /// Whether a reference that names nothing resolves to `false` instead of throwing.
  final bool reject;

  /// Schema object to the base URI it was indexed under.
  final baseOf = Map<Object, String>.identity();

  /// URI (with a `#name` fragment) of every `$dynamicAnchor`, to its schema.
  final dynamicAnchors = <String, Map<Object?, Object?>>{};

  final _registry = <String, Object>{};

  /// The references that named nothing and resolved to `false`.
  final _unresolved = <String>{};

  final _resources = <String, Object?>{};
  final _anchors = <String, Map<Object?, Object?>>{};
  var _indexed = false;

  /// The base URI of `node`, whose parent has `base`: its `$id` changes it, unless draft 7 makes the `$id` inert. Once
  /// the schema is indexed, the indexed base (a resolved reference target already has its own).
  String baseFor(Map<Object?, Object?> node, String base) {
    final known = baseOf[node];
    if (known != null) {
      return known;
    }

    final id = node[r'$id'];
    if (id is! String) {
      return base;
    }

    // Index before applying an `$id`: a caller's `base` may already include it, and the index applies it once.
    if (!_indexed) {
      index();
      final indexed = baseOf[node];
      if (indexed != null) {
        return indexed;
      }
    }

    if (draft == Draft.draft7 && (node[r'$ref'] is String || id.startsWith('#'))) {
      return base;
    }

    return documentOf(resolveUri(id, base));
  }

  /// Indexes the root schema and the registered documents' URIs (once).
  void index() {
    if (_indexed) {
      return;
    }

    _indexed = true;
    for (final MapEntry(:key, :value) in schemas.entries) {
      _registry[documentOf(resolveUri(key, defaultBase))] = value;
    }

    _resources[defaultBase] = root;
    _walk(root, defaultBase);
  }

  /// The schema a reference names, with the base URI it compiles under. Throws if it names nothing, or, when
  /// unresolved references are rejected, resolves to `false`, the schema no value passes.
  Resolved resolve(String ref, String base) {
    index();
    if (!reject) {
      return _find(ref, base);
    }

    try {
      return _find(ref, base);
    } on SchemaException {
      _unresolved.add(resolveUri(ref, base));
      return (node: false, base: base);
    }
  }

  /// Whether `ref`, from `base`, named nothing and resolved to `false`.
  bool isUnresolved(String ref, String base) => _unresolved.contains(resolveUri(ref, base));

  Resolved _find(String ref, String base) {
    final uri = resolveUri(ref, base);
    final doc = documentOf(uri);
    final fragment = uri.length > doc.length ? Uri.decodeComponent(uri.substring(doc.length + 1)) : '';
    final root = _resources.containsKey(doc) ? _resources[doc] : _load(doc);
    if (root == null) {
      throw SchemaException('Unresolved \$ref $ref (no schema registered for $doc)');
    }

    if (fragment.isEmpty) {
      return (node: root, base: doc);
    }

    if (fragment.startsWith('/')) {
      return _pointer(root, doc, fragment);
    }

    final target = _anchors['$doc#$fragment'];
    if (target == null) {
      throw SchemaException('Unresolved \$ref $ref (no anchor $fragment in $doc)');
    }

    return (node: target, base: baseOf[target] ?? doc);
  }

  /// Whether `node` is the root of the schema resource at `base`.
  bool isResource(Object node, String base) {
    index();
    return identical(_resources[base], node);
  }

  // Walks only keywords that hold subschemas: an `$id` inside `enum`, `const` or an unknown keyword names nothing.
  void _walk(Object? node, String base) {
    if (node is! Map || baseOf.containsKey(node)) {
      return;
    }

    var b = base;

    // In draft 7 a `$ref` makes every sibling keyword, `$id` included, inert.
    final refOnly = draft == Draft.draft7 && node[r'$ref'] is String;
    final id = node[r'$id'];
    if (!refOnly && id is String) {
      if (draft == Draft.draft7 && id.startsWith('#')) {
        _anchors[documentOf(b) + id] = node;
      } else {
        final uri = resolveUri(id, b);
        b = documentOf(uri);
        _resources[b] = node;
        if (uri.length > b.length + 1) {
          _anchors[uri] = node;
        }
      }
    }

    baseOf[node] = b;
    if (refOnly) {
      return;
    }

    if (draft != Draft.draft7) {
      if (node[r'$anchor'] case final String anchor) {
        _anchors['$b#$anchor'] = node;
      }

      if (node[r'$dynamicAnchor'] case final String anchor) {
        _anchors['$b#$anchor'] = node;
        dynamicAnchors['$b#$anchor'] = node;
      }
    }

    for (final key in _schemaKeywords) {
      _walk(node[key], b);
    }

    for (final key in _mapKeywords) {
      if (node[key] case final Map<Object?, Object?> map) {
        for (final s in map.values) {
          _walk(s, b);
        }
      }
    }

    for (final key in _listKeywords) {
      if (node[key] case final List<Object?> list) {
        for (final s in list) {
          _walk(s, b);
        }
      }
    }
  }

  Object? _load(String doc) {
    final schema = _registry[doc];
    if (schema == null) {
      return null;
    }

    _resources[doc] = schema;
    _walk(schema, doc);
    return schema;
  }

  Resolved _pointer(Object root, String base, String fragment) {
    Object? node = root;
    var b = base;
    for (final raw in fragment.split('/').skip(1)) {
      node =
          _child(node, raw.replaceAll('~1', '/').replaceAll('~0', '~')) ??
          (throw SchemaException('Unresolved \$ref #$fragment in $base'));
      if (node is Map) {
        b = baseOf[node] ?? b;
      }
    }

    return (node: node, base: b);
  }
}

// The member `key` of an object or array, null when there is none (a schema member is never null).
Object? _child(Object? node, String key) {
  if (node is Map) {
    return node[key];
  }

  if (node is! List) {
    return null;
  }

  final i = int.tryParse(key);
  if (i == null || i < 0 || i >= node.length) {
    return null;
  }

  return node[i];
}

const _schemaKeywords = [
  'additionalProperties',
  'propertyNames',
  'contains',
  'not',
  'if',
  'then',
  'else',
  'unevaluatedProperties',
  'unevaluatedItems',
  'additionalItems',
  'contentSchema',
  'items',
];

const _mapKeywords = ['properties', 'patternProperties', r'$defs', 'definitions', 'dependentSchemas', 'dependencies'];

const _listKeywords = ['allOf', 'anyOf', 'oneOf', 'prefixItems', 'items'];

/// `ref` resolved against `base`. Bases a URI parser rejects take fragment-only references.
String resolveUri(String ref, String base) {
  try {
    return Uri.parse(base).resolve(ref).toString();
  } on FormatException {
    return ref.startsWith('#') ? documentOf(base) + ref : ref;
  }
}

/// `uri` without its fragment.
String documentOf(String uri) {
  final hash = uri.indexOf('#');
  return hash < 0 ? uri : uri.substring(0, hash);
}
