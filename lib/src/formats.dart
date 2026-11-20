// The format checks of JSON Schema 2020-12, for compile()'s `formats` option. Adapted (through pi-schema) from TypeBox
// 1.3.27's format checks (MIT, (c) Haydn Paterson).

import 'idna.dart';

/// Every format JSON Schema 2020-12 defines, by name.
final Map<String, bool Function(String)> formats = Map.unmodifiable({
  'date': isDate,
  'date-time': isDateTime,
  'duration': _duration.hasMatch,
  'email': _email.hasMatch,
  'hostname': isHostname,
  'idn-email': _idnEmail.hasMatch,
  'idn-hostname': isIdnHostname,
  'ipv4': _ipv4.hasMatch,
  'ipv6': _ipv6.hasMatch,
  'iri': isIri,
  'iri-reference': isIriReference,
  'json-pointer': _jsonPointer.hasMatch,
  'regex': isRegex,
  'relative-json-pointer': _relativeJsonPointer.hasMatch,
  'time': isTime,
  'uri': _uri.hasMatch,
  'uri-reference': _uriReference.hasMatch,
  'uri-template': _uriTemplate.hasMatch,
  'uuid': _uuid.hasMatch,
});

const _days = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

final _date = RegExp(r'^(\d\d\d\d)-(\d\d)-(\d\d)$');

/// A full-date of RFC 3339.
bool isDate(String value) {
  final m = _date.firstMatch(value);
  if (m == null) {
    return false;
  }

  final year = int.parse(m[1]!);
  final month = int.parse(m[2]!);
  final day = int.parse(m[3]!);
  if (month < 1 || month > 12 || day < 1) {
    return false;
  }

  if (month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) {
    return day <= 29;
  }

  return day <= _days[month];
}

/// A date-time of RFC 3339.
bool isDateTime(String value) {
  final parts = value.split(RegExp('t', caseSensitive: false));
  return parts.length == 2 && isDate(parts[0]) && isTime(parts[1]);
}

final _time = RegExp(r'^(\d\d):(\d\d):(\d\d)(?:\.\d+)?(?:([Zz])|([+-])(\d\d):(\d\d))?$');

/// A full-time of RFC 3339, with its time zone; a leap second only at 23:59:60 UTC.
bool isTime(String value) {
  final m = _time.firstMatch(value);
  if (m == null) {
    return false;
  }

  if (m[4] == null && m[5] == null) {
    return false;
  }

  final hour = int.parse(m[1]!);
  final minute = int.parse(m[2]!);
  final second = int.parse(m[3]!);
  if (hour > 23 || minute > 59 || second > 60) {
    return false;
  }

  final zoneHour = int.parse(m[6] ?? '0');
  final zoneMinute = int.parse(m[7] ?? '0');
  if (zoneHour > 23 || zoneMinute > 59) {
    return false;
  }

  if (second < 60) {
    return true;
  }

  // A leap second is 23:59:60 in UTC (minute 1439 of the day).
  return (hour * 60 + minute - (m[5] == '-' ? -1 : 1) * (zoneHour * 60 + zoneMinute)) % 1440 == 1439;
}

/// A regular expression, as ECMAScript with Unicode reads it.
bool isRegex(String value) {
  try {
    RegExp(value, unicode: true);
    return true;
  } on FormatException {
    return false;
  }
}

final _invalidIriChars = RegExp(r'[\x00-\x20<>^`{|}\\]');
final _invalidPercent = RegExp(r'%(?![0-9a-fA-F]{2})');
final _ipvFuture = RegExp(r'\[[vV][0-9a-fA-F]+\.[^\]]+\]');

/// An IRI of RFC 3987: an absolute reference with a scheme.
bool isIri(String value) {
  if (_invalidIriChars.hasMatch(value) || _invalidPercent.hasMatch(value)) {
    return false;
  }

  // An IPvFuture literal is valid in RFC 3987 though URI parsers reject it: it parses as the IPv6 loopback.
  final uri = Uri.tryParse(value.length < 2048 ? value.replaceFirst(_ipvFuture, '[::1]') : value);
  return uri != null && uri.hasScheme;
}

final _invalidIriReferenceChars = RegExp(r'[\x00-\x20\x7F\\]|%(?![0-9a-fA-F]{2})');
final _malformedScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+\-.]*//');

/// An IRI reference of RFC 3987: absolute or relative.
bool isIriReference(String value) {
  if (_invalidIriReferenceChars.hasMatch(value) || _malformedScheme.hasMatch(value)) {
    return false;
  }

  return Uri.tryParse(value) != null;
}

final _duration = RegExp(
  r'^P((\d+Y(\d+M(\d+D)?)?|\d+M(\d+D)?|\d+D)(T(\d+H(\d+M(\d+S)?)?|\d+M(\d+S)?|\d+S))?|T(\d+H(\d+M(\d+S)?)?|\d+M(\d+S)?|\d+S)|\d+W)$',
);

final _email = RegExp(
  r'''^(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|"(?:[^"\\]|\\[\x20-\x7e])*")@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*|\[(?:IPv6:[a-f0-9:]+|(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3})\])$''',
  caseSensitive: false,
);

final _idnEmail = RegExp(
  r'''^(?:[A-Za-z0-9!#$%&'*+/=?^_`{|}~\u{0080}-\u{10FFFF}-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~\u{0080}-\u{10FFFF}-]+)*|"(?:[^"\\]|\\.)*")@[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,62})(?<!-)(?:\.[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,62})(?<!-))*$''',
  caseSensitive: false,
  unicode: true,
);

final _ipv4 = RegExp(r'^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$');

// An IPv4 address, as IPv6 addresses and URI hosts embed it.
const _v4 = r'(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)';

final _ipv6 = RegExp(
  r'^(?:(?:(?:[0-9a-f]{1,4}:){6}|::(?:[0-9a-f]{1,4}:){5}|(?:[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){4}|(?:(?:[0-9a-f]{1,4}:)?[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){3}|(?:(?:[0-9a-f]{1,4}:){0,2}[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){2}|(?:(?:[0-9a-f]{1,4}:){0,3}[0-9a-f]{1,4})?::[0-9a-f]{1,4}:|(?:(?:[0-9a-f]{1,4}:){0,4}[0-9a-f]{1,4})?::)(?:[0-9a-f]{1,4}:[0-9a-f]{1,4}|' +
      _v4 +
      r')|(?:(?:[0-9a-f]{1,4}:){0,5}[0-9a-f]{1,4})?::[0-9a-f]{1,4}|(?:(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{1,4})?::)$',
  caseSensitive: false,
);

final _uuid = RegExp(r'^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$', caseSensitive: false);

final _jsonPointer = RegExp(r'^(?:/(?:[^~/]|~0|~1)*)*$');

final _relativeJsonPointer = RegExp(r'^(?:0|[1-9][0-9]*)(?:#|(?:/(?:[^~/]|~0|~1)*)*)$');

// The IPv6 forms of a URI host, as TypeBox's URI patterns write them.
const _h16 = r'[\da-f]{1,4}';
const _ls32 = '(?:$_h16:$_h16|$_v4)';
const _ip6 =
    '(?:(?:$_h16:){6}$_ls32|::(?:$_h16:){5}$_ls32|(?:$_h16)?::(?:$_h16:){4}$_ls32|(?:(?:$_h16:){0,1}$_h16)?::(?:$_h16:){3}$_ls32|(?:(?:$_h16:){0,2}$_h16)?::(?:$_h16:){2}$_ls32|(?:(?:$_h16:){0,3}$_h16)?::$_h16:$_ls32|(?:(?:$_h16:){0,4}$_h16)?::$_ls32|(?:(?:$_h16:){0,5}$_h16)?::$_h16|(?:(?:$_h16:){0,6}$_h16)?::)';
const _pct = '%[0-9a-f]{2}';
const _host = "(?:\\[(?:$_ip6|v[0-9a-f]+\\.[-a-z0-9._~!\$&'()*+,;=:]+)\\]|$_v4|(?:[-a-z0-9._~!\$&'()*+,;=]|$_pct)*)";
const _userinfo = "(?:(?:[-a-z0-9._~!\$&'()*+,;=:]|$_pct)*@)?";
const _pchar = "(?:[-a-z0-9._~!\$&'()*+,;=:@]|$_pct)";
const _query = "(?:\\?(?:[-a-z0-9._~!\$&'()*+,;=:@/?]|$_pct)*)?";
const _fragment = "(?:#(?:[-a-z0-9._~!\$&'()*+,;=:@/?]|$_pct)*)?";
const _authorityPath = '//$_userinfo$_host(?::\\d*)?(?:/$_pchar*)*';
const _absolutePath = '/(?:$_pchar+(?:/$_pchar*)*)?';

final _uri = RegExp(
  '^[a-z][a-z0-9+\\-.]*:(?:$_authorityPath|$_absolutePath|$_pchar+(?:/$_pchar*)*)?$_query$_fragment\$',
  caseSensitive: false,
);

// A relative path's first segment has no colon.
final _uriReference = RegExp(
  '^(?:[a-z][a-z0-9+\\-.]*:(?:$_authorityPath|$_absolutePath|$_pchar+(?:/$_pchar*)*)?|'
  "(?:$_authorityPath|$_absolutePath|(?:[-a-z0-9._~!\$&'()*+,;=@]|$_pct)+(?:/$_pchar*)*)?)$_query$_fragment\$",
  caseSensitive: false,
);

final _uriTemplate = RegExp(
  r'^(?:(?:[^\x00-\x20"<>%\\^`{|}\x7f]|%[0-9a-f]{2})|\{[+#./;?&=,!@|]?(?:[a-z0-9_]|%[0-9a-f]{2})+(?:\.(?:[a-z0-9_]|%[0-9a-f]{2})+)*(?::[1-9]\d{0,3}|\*)?(?:,(?:[a-z0-9_]|%[0-9a-f]{2})+(?:\.(?:[a-z0-9_]|%[0-9a-f]{2})+)*(?::[1-9]\d{0,3}|\*)?)*\})*$',
  caseSensitive: false,
);
