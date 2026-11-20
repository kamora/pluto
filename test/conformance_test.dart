// The official JSON-Schema-Test-Suite, drafts 2020-12 and 7: every test, including optional and format tests. A test
// listed in `known` must fail; when one starts passing, remove it from the list.

import 'package:pluto/formats.dart';
import 'package:pluto/pluto.dart';
import 'package:test/test.dart';

import 'suite.dart';

const known = {
  // Vocabularies switched off by a custom meta-schema are not supported.
  'draft2020-12/vocabulary > schema that uses custom metaschema with with no validation vocabulary > '
      'no validation: invalid number, but it still validates',
  'draft2020-12/optional/format-assertion > schema that uses custom metaschema with format-assertion: false > '
      'format-assertion: false: invalid string',
  'draft2020-12/optional/format-assertion > schema that uses custom metaschema with format-assertion: true > '
      'format-assertion: true: invalid string',

  // A $ref to a document of another draft is evaluated with the compile's draft.
  'draft2020-12/optional/cross-draft > refs to historic drafts are processed as historic drafts > '
      'first item not a string is valid',
  'draft7/optional/cross-draft > refs to future drafts are processed as future drafts > missing bar is invalid',

  // Dart's core libraries have no Unicode normalization (NFC).
  'draft2020-12/optional/format/idn-email > validation of an internationalized e-mail addresses > '
      'a domain label that is not in Unicode NFC is valid',
  'draft7/optional/format/idn-email > validation of an internationalized e-mail addresses > '
      'a domain label that is not in Unicode NFC is valid',

  // contentMediaType and contentEncoding are annotations.
  'draft7/optional/content > validation of string-encoded content based on media type > an invalid JSON document',
  'draft7/optional/content > validation of binary string-encoding > an invalid base64 string (% is not a valid character)',
  'draft7/optional/content > validation of binary-encoded media type documents > a validly-encoded invalid JSON document',
  'draft7/optional/content > validation of binary-encoded media type documents > an invalid base64 string that is valid JSON',
};

void main() {
  final schemas = suiteSchemas();
  for (final file in suiteFiles()) {
    // Format tests assert formats; everywhere else `format` is an annotation, as draft 2020-12 specifies.
    final checks = file.name.contains('/optional/format/') ? formats : null;
    group(file.name, () {
      for (final g in file.groups.cast<Map<String, Object?>>()) {
        group(g['description'], () {
          for (final t in (g['tests'] as List).cast<Map<String, Object?>>()) {
            final name = '${file.name} > ${g['description']} > ${t['description']}';
            test(t['description'], () {
              final validator = compile(g['schema']!, draft: file.draft, formats: checks, schemas: schemas);
              expect(validator.check(t['data']), known.contains(name) ? isNot(t['valid']) : t['valid']);
              expect(
                validator.errors(t['data']).isEmpty,
                validator.check(t['data']),
                reason: 'errors agree with check',
              );
            });
          }
        });
      }
    });
  }
}
