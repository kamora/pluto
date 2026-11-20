// Hostnames of RFC 1123 and internationalized hostnames of IDNA 2008 (RFC 5890-5893), with Punycode (RFC 3492).
// Adapted (through pi-schema) from TypeBox 1.3.27's IDNA checks (MIT, (c) Haydn Paterson). Unicode normalization
// (NFC) is not applied: Dart's core libraries have none.

/// A hostname: ASCII labels of letters, digits and hyphens, or Punycode labels (`xn--`).
bool isHostname(String value) {
  if (value.isEmpty || value.length > 253 || value.endsWith('.')) {
    return false;
  }

  return value.split('.').every((label) => _validLength(label) && (_isPunyLabel(label) || _isAsciiLabel(label)));
}

/// An internationalized hostname: labels of Unicode or Punycode, with the Bidi rule for right-to-left names.
bool isIdnHostname(String value) {
  if (value.isEmpty || value.contains(' ')) {
    return false;
  }

  final normalized = _normalize(value);
  if (normalized.length > 253) {
    return false;
  }

  final labels = normalized.split('.');
  final bidi = labels.any(_hasBidiChars);
  return labels.every((label) {
    if (!_validLength(label) || !(_isPunyLabel(label) || _isUnicodeLabel(label))) {
      return false;
    }

    return !bidi || _satisfiesBidiRule(label);
  });
}

bool _validLength(String label) => label.isNotEmpty && label.length <= 63;

// Fullwidth ASCII to ASCII, code points IDNA mapping ignores removed, and full stop variants to '.'.
String _normalize(String value) {
  return value
      .replaceAllMapped(RegExp('[！-～]'), (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0xfee0))
      .replaceAll(RegExp(r'[­͏᠋-᠍​︀-️\u{e0100}-\u{e01ef}]', unicode: true), '')
      .replaceAll(RegExp('[.。．｡]'), '.');
}

// An ASCII LDH label of RFC 5891 §4.2.3.1.
bool _isAsciiLabel(String value) {
  return _hyphenPlacement.hasMatch(value) && _notReservedAce.hasMatch(value) && _asciiLdh.hasMatch(value);
}

bool _isAcePrefixed(String value) => value.toLowerCase().startsWith('xn--');

bool _isPunyLabel(String value) {
  if (!_isAcePrefixed(value)) {
    return false;
  }

  final body = value.substring(4).toLowerCase();

  // A payload of only a hyphen, or starting with the delimiter, has no basic characters before it: malformed.
  if (body.lastIndexOf('-') == 0) {
    return false;
  }

  final decoded = _decode(body);

  // RFC 5890 §2.3.2.1: a U-label has at least one non-ASCII character.
  if (decoded == null || !_nonAscii.hasMatch(decoded)) {
    return false;
  }

  return _isUnicodeLabel(decoded);
}

// RFC 5890 §2.3.2.1: an A-label ("xn--" and the Punycode) is at most 63 octets; only non-ASCII labels have one.
bool _exceedsMaxALabelLength(String value) => _nonAscii.hasMatch(value) && _encode(value).length + 4 > 63;

bool _isUnicodeLabel(String value) {
  if (_exceedsMaxALabelLength(value)) {
    return false;
  }

  // RFC 5893: the Bidi rule, whenever this label is right-to-left.
  if (_hasRightToLeft(value) && !_satisfiesBidiRule(value)) {
    return false;
  }

  final points = value.runes.toList();
  final chars = [for (final p in points) String.fromCharCode(p)];

  // RFC 5891 §4.2.3.2: no hyphen first, last, or in the 3rd and 4th positions.
  if (chars.first == '-' || chars.last == '-' || chars.skip(2).join().startsWith('--')) {
    return false;
  }

  // RFC 5891 §4.2.3.2: no combining mark first.
  if (_combiningMark.hasMatch(chars.first)) {
    return false;
  }

  var japanese = false;
  for (var i = 0; i < points.length; i++) {
    final char = chars[i];
    if (_disallowed.hasMatch(char) || !_permittedCategory.hasMatch(char)) {
      return false;
    }

    if (_japanese.hasMatch(char)) {
      japanese = true;
    }

    if (!_contextOk(points, chars, i)) {
      return false;
    }
  }

  // RFC 5892 Appendix A.7: a KATAKANA MIDDLE DOT needs a Japanese character in the label.
  return japanese || !value.contains('・');
}

// The CONTEXTO and CONTEXTJ rules of RFC 5892 Appendix A for the code point at `i`.
bool _contextOk(List<int> points, List<String> chars, int i) {
  final prev = i > 0 ? points[i - 1] : null;
  final next = i + 1 < points.length ? points[i + 1] : null;
  return switch (points[i]) {
    // MIDDLE DOT (Catalan): between two l's.
    0x00b7 => prev == 0x006c && next == 0x006c,

    // Greek KERAIA: before a Greek character.
    0x0375 => next != null && _greek.hasMatch(chars[i + 1]),

    // Hebrew GERESH and GERSHAYIM: after a Hebrew character.
    0x05f3 || 0x05f4 => prev != null && _hebrew.hasMatch(chars[i - 1]),

    // ZWNJ: full validation needs the joining type table; only one after ASCII that is no virama is rejected.
    0x200c => prev != null && (prev >= 0x0080 || _virama.hasMatch(chars[i - 1])),

    // ZWJ: after a virama.
    0x200d => prev != null && _virama.hasMatch(chars[i - 1]),
    _ => true,
  };
}

// The Bidi rule of RFC 5893.

bool _hasBidiChars(String value) {
  if (!_isAcePrefixed(value)) {
    return _hasRightToLeft(value);
  }

  final decoded = _decode(value.substring(4).toLowerCase());
  return decoded != null && _hasRightToLeft(decoded);
}

String _bidiClass(String char) {
  if (_europeanNumber.hasMatch(char)) {
    return 'EN';
  }

  if (_arabicIndicDigit.hasMatch(char)) {
    return 'AN';
  }

  if (_nonSpacingMark.hasMatch(char)) {
    return 'NSM';
  }

  if (_hebrew.hasMatch(char)) {
    return 'R';
  }

  if (_arabicLetter.hasMatch(char)) {
    return 'AL';
  }

  return _letter.hasMatch(char) ? 'L' : 'ON';
}

// RFC 5893 §1.4: a right-to-left label has a character of class R, AL or AN.
bool _hasRightToLeft(String value) {
  return value.runes.any((p) => const {'R', 'AL', 'AN'}.contains(_bidiClass(String.fromCharCode(p))));
}

bool _satisfiesBidiRule(String value) {
  final classes = [for (final p in value.runes) _bidiClass(String.fromCharCode(p))];
  if (classes.isEmpty) {
    return true;
  }

  // 1. The first character is L, R or AL.
  final first = classes.first;
  if (first != 'L' && first != 'R' && first != 'AL') {
    return false;
  }

  // 2 and 5. Only the classes of the label's direction.
  final rtl = first != 'L';
  if (!classes.every((rtl ? _rtlAllowed : _ltrAllowed).contains)) {
    return false;
  }

  // 4. A right-to-left label has no EN with AN.
  if (!rtl) {
    return true;
  }

  return !(classes.contains('EN') && classes.contains('AN'));
}

const _rtlAllowed = {'R', 'AL', 'AN', 'EN', 'ES', 'CS', 'ET', 'ON', 'BN', 'NSM'};
const _ltrAllowed = {'L', 'EN', 'ES', 'CS', 'ET', 'ON', 'BN', 'NSM'};

// Punycode (RFC 3492).

const _base = 36;
const _tmin = 1;
const _tmax = 26;
const _skew = 38;
const _damp = 700;
const _initialBias = 72;
const _initialN = 128;

int _adapt(int delta, int points, bool first) {
  var d = first ? delta ~/ _damp : delta >> 1;
  d += d ~/ points;
  var k = 0;
  while (d > ((_base - _tmin) * _tmax) >> 1) {
    d ~/= _base - _tmin;
    k += _base;
  }

  return k + ((_base - _tmin + 1) * d) ~/ (d + _skew);
}

int _threshold(int k, int bias) {
  if (k <= bias) {
    return _tmin;
  }

  return k >= bias + _tmax ? _tmax : k - bias;
}

// The Unicode of a Punycode payload, null when it is malformed.
String? _decode(String value) {
  final output = <int>[];
  var n = _initialN;
  var i = 0;
  var bias = _initialBias;
  final delimiter = value.lastIndexOf('-');
  for (var j = 0; j < delimiter; j++) {
    final c = value.codeUnitAt(j);
    if (c >= 128) {
      return null;
    }

    output.add(c);
  }

  var index = delimiter < 0 ? 0 : delimiter + 1;
  while (index < value.length) {
    final old = i;
    var w = 1;
    for (var k = _base; ; k += _base) {
      if (index >= value.length) {
        return null;
      }

      final c = value.codeUnitAt(index++);
      final int digit;
      if (c >= 0x61 && c <= 0x7a) {
        digit = c - 0x61;
      } else if (c >= 0x30 && c <= 0x39) {
        digit = c - 0x30 + 26;
      } else {
        return null;
      }

      i += digit * w;
      final t = _threshold(k, bias);
      if (digit < t) {
        break;
      }

      w *= _base - t;
    }

    final length = output.length + 1;
    bias = _adapt(i - old, length, old == 0);
    n += i ~/ length;
    i %= length;
    if (n > 0x10ffff) {
      return null;
    }

    output.insert(i, n);
    i++;
  }

  return String.fromCharCodes(output);
}

// The Punycode payload of a Unicode string (what follows "xn--").
String _encode(String input) {
  final basic = input.replaceAll(RegExp(r'[^\p{ASCII}]', unicode: true), '');
  final out = StringBuffer(basic.isEmpty ? '' : '$basic-');
  final points = input.runes.toList();
  var n = _initialN;
  var delta = 0;
  var bias = _initialBias;
  var handled = basic.length;
  while (handled < points.length) {
    final m = points.where((p) => p >= n).reduce((a, b) => a < b ? a : b);
    delta += (m - n) * (handled + 1);
    n = m;
    for (final p in points) {
      if (p < n) {
        delta++;
      }

      if (p != n) {
        continue;
      }

      var q = delta;
      for (var k = _base; ; k += _base) {
        final t = _threshold(k, bias);
        if (q < t) {
          break;
        }

        out.write(_digit(t + (q - t) % (_base - t)));
        q = (q - t) ~/ (_base - t);
      }

      out.write(_digit(q));
      bias = _adapt(delta, handled + 1, handled == basic.length);
      delta = 0;
      handled++;
    }

    delta++;
    n++;
  }

  return out.toString();
}

String _digit(int d) => String.fromCharCode(d < 26 ? d + 0x61 : d - 26 + 0x30);

// Patterns.

final _hyphenPlacement = RegExp(r'^(?!-).*(?<!-)$');
final _notReservedAce = RegExp(r'^(?!..--)');
final _asciiLdh = RegExp(r'^[a-zA-Z0-9-]*$');
final _nonAscii = RegExp(r'[^\p{ASCII}]', unicode: true);
final _arabicIndicDigit = RegExp(r'[\u{0660}-\u{0669}]', unicode: true);
final _europeanNumber = RegExp(r'[0-9]|[\u{06f0}-\u{06f9}]', unicode: true);
final _nonSpacingMark = RegExp(r'\p{Mn}', unicode: true);
final _combiningMark = RegExp(r'[\p{Mn}\p{Mc}\p{Me}]', unicode: true);
final _letter = RegExp(r'\p{L}', unicode: true);
final _greek = RegExp(r'\p{Script=Greek}', unicode: true);
final _hebrew = RegExp(r'\p{Script=Hebrew}', unicode: true);
final _japanese = RegExp(r'[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]', unicode: true);
final _arabicLetter = RegExp(r'[\p{Script=Arabic}\p{Script=Syriac}\p{Script=Thaana}\p{Script=Mandaic}]', unicode: true);
final _virama = RegExp(
  r'[\u{094d}\u{09cd}\u{0a4d}\u{0acd}\u{0b4d}\u{0bcd}\u{0c4d}\u{0ccd}\u{0d3b}\u{0d3c}\u{0d4d}\u{0dca}\u{1b44}\u{1baa}\u{1bab}\u{a9c0}\u{11046}\u{1107f}\u{110b9}\u{11133}\u{11134}\u{111c0}\u{11235}\u{1134d}\u{11442}\u{114c2}\u{115bf}\u{1163f}\u{116b6}\u{11c3f}\u{11d44}\u{11d45}]',
  unicode: true,
);
final _disallowed = RegExp(
  r'[\u{0640}\u{07fa}\u{302e}\u{302f}\u{3031}\u{3032}\u{3033}\u{3034}\u{3035}\u{303b}]',
  unicode: true,
);

// Letters, separators (- + . , : /), decimal digits, non-spacing and spacing marks, and the CONTEXTO and PVALID
// exceptions of RFC 5892.
final _permittedCategory = RegExp(
  r'\p{L}|[\u{002d}\u{002b}]|[\u{002e}\u{002c}\u{003a}\u{002f}]|\p{Nd}|\p{Mn}|\p{Mc}'
  r'|[\u{00b7}\u{0375}\u{05f3}\u{05f4}\u{200c}\u{200d}\u{30fb}]|[\u{00df}\u{03c2}\u{06fd}\u{06fe}\u{0f0b}\u{3007}]',
  unicode: true,
);
