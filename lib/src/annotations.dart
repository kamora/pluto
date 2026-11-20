// Annotation tracking for `unevaluatedProperties` and `unevaluatedItems`: annotating checks record which properties
// and items a schema evaluated. Only schemas that use those keywords compile into these closures.

import 'checks.dart';

/// What a schema evaluated: property names (or all of them), the evaluated item prefix, items matched by `contains`.
class Annotations {
  final props = <Object?>{};
  var allProps = false;
  var items = 0;
  var allItems = false;
  final indexes = <int>{};

  void merge(Annotations b) {
    props.addAll(b.props);
    allProps = allProps || b.allProps;
    if (b.items > items) {
      items = b.items;
    }

    allItems = allItems || b.allItems;
    indexes.addAll(b.indexes);
  }
}

/// A check that records what it evaluated into `a` when it passes.
typedef AnnotatingCheck = bool Function(Object? value, Annotations a);

bool annotatingTrue(Object? v, Annotations a) => true;

bool annotatingFalse(Object? v, Annotations a) => false;

/// A plain check in annotating position: it evaluates nothing that unevaluated* sees.
AnnotatingCheck ignoreAnnotations(Check check) =>
    (v, a) => check(v);

/// An annotating check run as a plain check, with fresh annotations.
Check withFreshAnnotations(AnnotatingCheck check) =>
    (v) => check(v, Annotations());

/// `check` with `uri` pushed onto the dynamic scope while it runs.
AnnotatingCheck scopedAnnotating(List<String> scope, String uri, AnnotatingCheck check) {
  return (v, a) {
    scope.add(uri);
    try {
      return check(v, a);
    } finally {
      scope.removeLast();
    }
  };
}

/// unevaluated* sees only the annotations of its own schema, never those of its siblings in the parent.
AnnotatingCheck isolateAnnotations(AnnotatingCheck check) {
  return (v, a) {
    final b = Annotations();
    if (!check(v, b)) {
      return false;
    }

    a.merge(b);
    return true;
  };
}

/// The non-annotating keywords, then each annotating part in order.
AnnotatingCheck annotateAll(Check plain, List<AnnotatingCheck> parts) {
  return (v, a) => plain(v) && parts.every((part) => part(v, a));
}

/// `properties`, `patternProperties` and `additionalProperties`.
AnnotatingCheck annotateObject(Map<String, Check> props, List<(RegExp, Check)> patterns, Check? additional) {
  return (v, a) {
    if (v is! Map) {
      return true;
    }

    final seen = <Object?>[];
    for (final MapEntry(:key, :value) in v.entries) {
      var matched = false;
      final check = props[key];
      if (check != null) {
        if (!check(value)) {
          return false;
        }

        matched = true;
        seen.add(key);
      }

      for (final (re, check) in patterns) {
        if (re.hasMatch(key as String)) {
          if (!check(value)) {
            return false;
          }

          matched = true;
          seen.add(key);
        }
      }

      if (!matched && additional != null) {
        if (!additional(value)) {
          return false;
        }

        seen.add(key);
      }
    }

    a.props.addAll(seen);
    return true;
  };
}

/// `prefixItems`/`items`/`additionalItems` and `contains` with its bounds.
AnnotatingCheck annotateArray(List<Check> prefix, Check? rest, Check? contains, num minContains, num maxContains) {
  return (v, a) {
    if (v is! List) {
      return true;
    }

    final m = v.length < prefix.length ? v.length : prefix.length;
    for (var i = 0; i < m; i++) {
      if (!prefix[i](v[i])) {
        return false;
      }
    }

    if (rest != null) {
      for (var i = prefix.length; i < v.length; i++) {
        if (!rest(v[i])) {
          return false;
        }
      }

      a.allItems = true;
    }

    if (m > a.items) {
      a.items = m;
    }

    if (contains == null) {
      return true;
    }

    var n = 0;
    for (var i = 0; i < v.length; i++) {
      if (contains(v[i])) {
        n++;
        a.indexes.add(i);
      }
    }

    return n >= minContains && n <= maxContains;
  };
}

/// `anyOf` (or `oneOf` when `exactlyOne`): every passing branch contributes its annotations.
AnnotatingCheck annotateAny(List<AnnotatingCheck> branches, bool exactlyOne) {
  return (v, a) {
    var n = 0;
    for (final branch in branches) {
      final b = Annotations();
      if (branch(v, b)) {
        n++;
        a.merge(b);
      }
    }

    return exactlyOne ? n == 1 : n > 0;
  };
}

/// `if`, `then` and `else`: a passing `if` contributes its annotations even without `then`.
AnnotatingCheck annotateIf(AnnotatingCheck cond, AnnotatingCheck? then, AnnotatingCheck? otherwise) {
  return (v, a) {
    final b = Annotations();
    if (cond(v, b)) {
      a.merge(b);
      return then == null || then(v, a);
    }

    return otherwise == null || otherwise(v, a);
  };
}

/// One `dependentSchemas` entry.
AnnotatingCheck annotateDependent(String key, AnnotatingCheck check) {
  return (v, a) => v is! Map || !v.containsKey(key) || check(v, a);
}

/// `unevaluatedProperties`: every property no other keyword evaluated passes `check`.
AnnotatingCheck unevaluatedProperties(Check check) {
  return (v, a) {
    if (v is! Map || a.allProps) {
      return true;
    }

    for (final MapEntry(:key, :value) in v.entries) {
      if (!a.props.contains(key) && !check(value)) {
        return false;
      }
    }

    a.allProps = true;
    return true;
  };
}

/// `unevaluatedItems`: every item no other keyword evaluated passes `check`.
AnnotatingCheck unevaluatedItems(Check check) {
  return (v, a) {
    if (v is! List || a.allItems) {
      return true;
    }

    for (var i = a.items; i < v.length; i++) {
      if (!a.indexes.contains(i) && !check(v[i])) {
        return false;
      }
    }

    a.allItems = true;
    return true;
  };
}
