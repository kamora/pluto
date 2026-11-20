// Loads the vendored JSON-Schema-Test-Suite: its test files, the remote documents and the official meta-schemas.

import 'dart:convert';
import 'dart:io';

import 'package:pluto/pluto.dart';

/// One test file: its path below `tests/`, its draft and its groups.
typedef SuiteFile = ({String name, Draft draft, List<Object?> groups});

const _fixtures = 'test/fixtures';
const _root = '$_fixtures/json-schema-test-suite';

/// Every test file of drafts 2020-12 and 7.
List<SuiteFile> suiteFiles() {
  return [
    for (final (dir, draft) in [('draft2020-12', Draft.draft2020), ('draft7', Draft.draft7)])
      for (final file in _jsonFiles('$_root/tests/$dir'))
        (
          name: file.path.substring('$_root/tests/'.length).replaceFirst(RegExp(r'\.json$'), ''),
          draft: draft,
          groups: _read(file.path) as List<Object?>,
        ),
  ];
}

/// The remote documents and meta-schemas the tests reference, by URI.
Map<String, Object> suiteSchemas() {
  const remotes = '$_root/remotes';
  const meta = '$_fixtures/meta-schemas';
  return {
    for (final file in _jsonFiles(remotes))
      'http://localhost:1234/${file.path.substring(remotes.length + 1)}': _read(file.path),
    'http://json-schema.org/draft-07/schema': _read('$meta/draft-07-schema.json'),
    'https://json-schema.org/draft/2020-12/schema': _read('$meta/draft2020-12-schema.json'),
    for (final v in ['core', 'applicator', 'unevaluated', 'validation', 'meta-data', 'format-annotation', 'content'])
      'https://json-schema.org/draft/2020-12/meta/$v': _read('$meta/draft2020-12-meta-$v.json'),
  };
}

Object _read(String path) => jsonDecode(File(path).readAsStringSync()) as Object;

List<File> _jsonFiles(String dir) {
  return Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}
