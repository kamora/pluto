// Runs the whole JSON-Schema-Test-Suite and prints every failure, then the pass counts per draft. The known failures
// are in test/conformance_test.dart.

import 'package:pluto/formats.dart';
import 'package:pluto/pluto.dart';

import '../test/suite.dart';

void main() {
  final schemas = suiteSchemas();
  final counts = <String, List<int>>{};
  for (final file in suiteFiles()) {
    final c = counts.putIfAbsent(
      '${file.draft.name} ${file.name.contains('/optional/') ? 'optional' : 'core'}',
      () => [0, 0],
    );
    for (final group in file.groups.cast<Map<String, Object?>>()) {
      for (final t in (group['tests'] as List).cast<Map<String, Object?>>()) {
        c[1]++;
        final failure = _failure(file, group['schema']!, t, schemas);
        if (failure == null) {
          c[0]++;
        } else {
          print('${file.name} > ${group['description']} > ${t['description']}: $failure');
        }
      }
    }
  }

  for (final MapEntry(:key, :value) in counts.entries) {
    print('$key: ${value[0]} / ${value[1]}');
  }
}

// Why the test `t` fails, or null when it passes.
String? _failure(SuiteFile file, Object schema, Map<String, Object?> t, Map<String, Object> schemas) {
  try {
    final v = compile(
      schema,
      draft: file.draft,
      formats: file.name.contains('/optional/format/') ? formats : null,
      schemas: schemas,
    );
    if (v.check(t['data']) != t['valid']) {
      return 'got ${!(t['valid'] as bool)}';
    }

    if (v.errors(t['data']).isEmpty != v.check(t['data'])) {
      return 'errors disagree with check';
    }

    return null;
  } on Exception catch (e) {
    return '$e';
  }
}
