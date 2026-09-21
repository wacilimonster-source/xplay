// Parsing helpers for the timestamps X/Twitter returns in `created_at`.
//
// Those are RFC 822 / RFC 1123 style strings, e.g.
// `Mon Aug 25 14:03:22 +0000 2025`.
//
// A `DateFormat("EEE MMM dd HH:mm:ss Z yyyy")` cannot read them: in intl the
// `Z` field consumes no input at all (see `date_format_field.dart`, it is a
// bare `case 'Z': break;`), so the literal space after it gets matched against
// `+0000` and parsing throws `FormatException: Trying to read  from ...`.
// The ISO-8601 fallback cannot read this shape either, so every tweet used to
// end up with `createdAt == null` — which made `created_at` NULL in the
// database and let `pruneCachedMedia` delete the whole cache table.
//
// This parser is dependency-free (no locale data needed) and honours the
// `±HHMM` offset. It returns a UTC [DateTime]; the stored value is an absolute
// instant, so the UI can call `.toLocal()` freely.

/// `EEE MMM dd HH:mm:ss <zone> yyyy`, weekday and zone both optional.
final RegExp _twitterDate = RegExp(
  r'^(?:[A-Za-z]{3,9},?\s+)?' // Mon / Monday, optional comma
  r'([A-Za-z]{3,9})\s+' // month name
  r'(\d{1,2})\s+' // day
  r'(\d{1,2}):(\d{2}):(\d{2})(?:\.\d+)?' // time
  r'(?:\s+([A-Za-z]{1,4}\d{1,2}|[A-Za-z]{2,4}|[+-]\d{2}\d{2}))?' // zone
  r'\s*(\d{4})\s*$', // year
  caseSensitive: false,
);

/// `+0000` / `-0700` inside the zone field.
final RegExp _numericOffset = RegExp(r'([+-])(\d{2})(\d{2})');

/// Zones that already mean UTC and carry no numeric offset.
const Set<String> _utcZoneNames = {'utc', 'gmt', 'z', 'ut', 'est', 'edt'};

DateTime? parseTwitterDateTime(String? dateStr) {
  final trimmed = dateStr?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  final match = _twitterDate.firstMatch(trimmed);
  if (match == null) {
    // Anything the API starts sending that is not the legacy shape: ISO-8601.
    final iso = DateTime.tryParse(trimmed);
    if (iso != null) return iso.toUtc();
    return parseTwitterEpochMillis(trimmed);
  }

  final month = _months[match.group(1)!.toLowerCase()];
  final day = int.tryParse(match.group(2)!);
  final hour = int.tryParse(match.group(3)!);
  final minute = int.tryParse(match.group(4)!);
  final second = int.tryParse(match.group(5)!);
  final year = int.tryParse(match.group(7)!);
  final zone = match.group(6);
  if (month == null ||
      day == null ||
      hour == null ||
      minute == null ||
      second == null ||
      year == null) {
    return null;
  }

  var offsetMinutes = 0;
  if (zone != null) {
    final numeric = _numericOffset.firstMatch(zone);
    if (numeric != null) {
      offsetMinutes =
          (int.parse(numeric.group(2)!) * 60) + int.parse(numeric.group(3)!);
      if (numeric.group(1) == '-') offsetMinutes = -offsetMinutes;
    } else if (!_utcZoneNames.contains(zone.toLowerCase())) {
      // Unknown alphabetic zone: refuse to guess, let the caller fall back.
      return null;
    }
  }

  try {
    return DateTime.utc(year, month, day, hour, minute, second)
        .subtract(Duration(minutes: offsetMinutes));
  } catch (_) {
    return null; // Impossible calendar values (month 13, day 32, ...).
  }
}

/// Parses a `created_at_ms` style epoch-milliseconds value.
DateTime? parseTwitterEpochMillis(Object? value) {
  if (value == null) return null;
  final ms = int.tryParse(value.toString());
  if (ms == null || ms <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// Month name -> month number, so the parser stays locale-free.
const Map<String, int> _months = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
  'january': 1,
  'february': 2,
  'march': 3,
  'april': 4,
  'june': 6,
  'july': 7,
  'august': 8,
  'september': 9,
  'october': 10,
  'november': 11,
  'december': 12,
};
