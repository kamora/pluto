// The README's examples.

import 'package:pluto/pluto.dart';

void main() {
  final read = compile({
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'minLength': 1},
      'offset': {'type': 'integer', 'minimum': 1},
    },
    'required': ['path'],
    'additionalProperties': false,
  });

  print(read.check({'path': 'a.txt'}));
  read.errors({'offset': 0, 'extra': true}).forEach(print);
  print(read.parse({'path': 'a.txt', 'offset': '10'}));
  print(read.parse({'path': 'a.txt', 'offset': 'ten'}));
}
