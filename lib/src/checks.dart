// Check factories: each returns a closure that captures only its arguments, never the compiler, so a compiled schema
// keeps no compile-time state alive.

/// A compiled boolean check.
typedef Check = bool Function(Object? value);

bool always(Object? v) => true;

bool never(Object? v) => false;

bool isString(Object? v) => v is String;

/// A number is finite: JSON has no NaN or Infinity, so only a value built in code can be one.
bool isNumber(Object? v) => v is num && v.isFinite;

/// An integer is any number without a fraction: 1.0 is one, as JSON Schema counts it.
bool isInteger(Object? v) {
  if (v is int) {
    return true;
  }

  return v is double && v.isFinite && v == v.truncateToDouble();
}

bool isBoolean(Object? v) => v is bool;

bool isNull(Object? v) => v == null;

bool isArray(Object? v) => v is List;

bool isObject(Object? v) => v is Map;

/// The check of each `type` name.
const typeChecks = <String, Check>{
  'string': isString,
  'number': isNumber,
  'integer': isInteger,
  'boolean': isBoolean,
  'null': isNull,
  'array': isArray,
  'object': isObject,
};

/// All of `parts`.
Check and(List<Check> parts) {
  return switch (parts.length) {
    0 => always,
    1 => parts[0],
    _ => (v) => parts.every((check) => check(v)),
  };
}

/// A check whose implementation is set later: the indirection a recursive reference goes through.
class Slot<T extends Function> {
  late T check;
}

/// `check` with `uri` pushed onto the dynamic scope while it runs.
Check scopedCheck(List<String> scope, String uri, Check check) {
  return (v) {
    scope.add(uri);
    try {
      return check(v);
    } finally {
      scope.removeLast();
    }
  };
}

/// Any of the named types; an unknown name matches nothing.
Check typeCheck(List<Object?> types) {
  final checks = [for (final t in types) typeChecks[t] ?? never];
  if (checks.length == 1) {
    return checks[0];
  }

  return (v) => checks.any((check) => check(v));
}

/// The number of Unicode code points of `s`: JSON Schema string lengths count code points, not UTF-16 units.
int codePoints(String s) => s.runes.length;

/// The string keywords: length bounds, pattern and format. Other values pass unless `strict`.
Check stringCheck(bool strict, num min, num max, RegExp? re, bool Function(String)? format) {
  return (v) {
    if (v is! String) {
      return !strict;
    }

    final n = codePoints(v);
    if (n < min || n > max) {
      return false;
    }

    if (re != null && !re.hasMatch(v)) {
      return false;
    }

    return format == null || format(v);
  };
}

/// The number keywords. `strict` requires a number (`integer` an integer); otherwise other values pass.
Check numberCheck(bool strict, bool integer, num min, num max, num xmin, num xmax, num? multipleOf) {
  return (v) {
    if (v is! num) {
      return !strict;
    }

    if (!v.isFinite) {
      return false;
    }

    if (integer && !isInteger(v)) {
      return false;
    }

    if (v < min || v > max || v <= xmin || v >= xmax) {
      return false;
    }

    return multipleOf == null || isMultiple(v, multipleOf);
  };
}

/// Whether `v` is a multiple of `d`, exactly for decimals: 0.0075 / 0.0001 is 74.99999999999999 in floating point.
bool isMultiple(num v, num d) {
  final q = v / d;
  if (q.isFinite && q == q.truncateToDouble()) {
    return true;
  }

  if (!q.isFinite) {
    return v % d == 0;
  }

  final (vc, ve) = _decimal(v);
  final (dc, de) = _decimal(d);
  if (ve >= de) {
    return (vc * BigInt.from(10).pow(ve - de)) % dc == BigInt.zero;
  }

  return vc % (dc * BigInt.from(10).pow(de - ve)) == BigInt.zero;
}

// A number as an integer coefficient and a power of ten, from its shortest decimal form.
(BigInt, int) _decimal(num x) {
  final parts = x.abs().toString().split('e');
  final mantissa = parts[0].endsWith('.0') ? parts[0].substring(0, parts[0].length - 2) : parts[0];
  final point = mantissa.indexOf('.');
  return (
    BigInt.parse(mantissa.replaceFirst('.', '')),
    (parts.length > 1 ? int.parse(parts[1]) : 0) - (point < 0 ? 0 : mantissa.length - point - 1),
  );
}

/// `inner` for objects; other values pass unless `strict`.
Check guardObject(Check inner, bool strict) {
  if (strict) {
    return (v) => v is Map && inner(v);
  }

  return (v) => v is! Map || inner(v);
}

/// `inner` for arrays; other values pass unless `strict`.
Check guardArray(Check inner, bool strict) {
  if (strict) {
    return (v) => v is List && inner(v);
  }

  return (v) => v is! List || inner(v);
}

/// `properties`, `required`, `patternProperties` and `additionalProperties` (`v` is an object).
Check propertiesCheck(
  Map<String, Check> properties,
  List<String> required,
  List<(RegExp, Check)> patterns,
  Check? additional,
) {
  return (v) {
    final o = v as Map<Object?, Object?>;
    for (final k in required) {
      if (!o.containsKey(k)) {
        return false;
      }
    }

    for (final MapEntry(:key, :value) in o.entries) {
      var matched = false;
      final check = properties[key];
      if (check != null) {
        if (!check(value)) {
          return false;
        }

        matched = true;
      }

      for (final (re, check) in patterns) {
        if (re.hasMatch(key as String)) {
          if (!check(value)) {
            return false;
          }

          matched = true;
        }
      }

      if (!matched && additional != null && !additional(value)) {
        return false;
      }
    }

    return true;
  };
}

/// Every property name passes `check` (`v` is an object).
Check propertyNamesCheck(Check check) =>
    (v) => (v as Map<Object?, Object?>).keys.every(check);

/// `minProperties` and `maxProperties` (`v` is an object).
Check propertyCountCheck(num min, num max) {
  return (v) {
    final n = (v as Map<Object?, Object?>).length;
    return n >= min && n <= max;
  };
}

/// `dependentRequired` (`v` is an object).
Check dependentRequiredCheck(List<(String, List<Object?>)> entries) {
  return (v) {
    final o = v as Map<Object?, Object?>;
    return entries.every((e) => !o.containsKey(e.$1) || e.$2.every(o.containsKey));
  };
}

/// `dependentSchemas` (`v` is an object).
Check dependentSchemasCheck(List<(String, Check)> entries) {
  return (v) => entries.every((e) => !(v as Map<Object?, Object?>).containsKey(e.$1) || e.$2(v));
}

/// Prefix items and the items after them (`v` is an array).
Check itemsCheck(List<Check> prefix, Check? rest) {
  return (v) {
    final list = v as List<Object?>;
    for (var i = 0; i < list.length; i++) {
      final check = i < prefix.length ? prefix[i] : rest;
      if (check != null && !check(list[i])) {
        return false;
      }
    }

    return true;
  };
}

/// `minItems` and `maxItems` (`v` is an array).
Check lengthCheck(num min, num max) {
  return (v) {
    final n = (v as List<Object?>).length;
    return n >= min && n <= max;
  };
}

/// `contains` with its bounds (`v` is an array).
Check containsCheck(Check check, num min, num max) {
  return (v) {
    var n = 0;
    for (final item in v as List<Object?>) {
      if (check(item) && ++n > max) {
        return false;
      }
    }

    return n >= min;
  };
}

/// `uniqueItems` (`v` is an array).
bool uniqueCheck(Object? v) {
  final list = v as List<Object?>;
  for (var i = 1; i < list.length; i++) {
    for (var j = 0; j < i; j++) {
      if (deepEqual(list[i], list[j])) {
        return false;
      }
    }
  }

  return true;
}

/// `enum`.
Check enumCheck(List<Object?> values) =>
    (v) => values.any((x) => deepEqual(v, x));

/// `const`.
Check constCheck(Object? value) =>
    (v) => deepEqual(v, value);

/// `anyOf`.
Check anyCheck(List<Check> checks) =>
    (v) => checks.any((check) => check(v));

/// `oneOf`.
Check oneCheck(List<Check> checks) {
  return (v) {
    var n = 0;
    for (final check in checks) {
      if (check(v) && ++n > 1) {
        return false;
      }
    }

    return n == 1;
  };
}

/// `not`.
Check notCheck(Check check) =>
    (v) => !check(v);

/// `if`, `then` and `else`.
Check ifCheck(Check cond, Check then, Check otherwise) =>
    (v) => cond(v) ? then(v) : otherwise(v);

/// JSON equality, as `const`, `enum` and `uniqueItems` compare: numbers by value (1 equals 1.0), arrays with equal
/// items in order, objects with the same keys and equal values (key order does not matter).
bool deepEqual(Object? a, Object? b) {
  if (a is num && b is num) {
    return a == b;
  }

  if (a is List && b is List) {
    if (a.length != b.length) {
      return false;
    }

    for (var i = 0; i < a.length; i++) {
      if (!deepEqual(a[i], b[i])) {
        return false;
      }
    }

    return true;
  }

  if (a is Map && b is Map) {
    if (a.length != b.length) {
      return false;
    }

    for (final MapEntry(:key, :value) in a.entries) {
      if (!b.containsKey(key) || !deepEqual(value, b[key])) {
        return false;
      }
    }

    return true;
  }

  if (a is List || a is Map || b is List || b is Map) {
    return false;
  }

  return a == b;
}
