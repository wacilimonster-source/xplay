import 'package:flutter_test/flutter_test.dart';
import 'package:xplay/core/utils/date_utils.dart';

void main() {
  group('parseTwitterDateTime', () {
    test('reads the RFC 822 shape X returns (was always null before the fix)',
        () {
      final parsed = parseTwitterDateTime('Mon Aug 25 14:03:22 +0000 2025');
      expect(parsed, isNotNull);
      expect(parsed!.toUtc(), DateTime.utc(2025, 8, 25, 14, 3, 22));
    });

    test('honours a negative UTC offset', () {
      final parsed = parseTwitterDateTime('Wed Jun 04 07:11:05 -0700 2025');
      expect(parsed!.toUtc(), DateTime.utc(2025, 6, 4, 14, 11, 5));
    });

    test('honours a positive UTC offset', () {
      final parsed = parseTwitterDateTime('Fri Nov 28 18:59:01 +0530 2025');
      expect(parsed!.toUtc(), DateTime.utc(2025, 11, 28, 13, 29, 1));
    });

    test('accepts named zones and missing weekday', () {
      expect(parseTwitterDateTime('Tue Apr 01 10:00:00 GMT 2025'),
          DateTime.utc(2025, 4, 1, 10));
      expect(parseTwitterDateTime('Apr 01 10:00:00 +0000 2025'),
          DateTime.utc(2025, 4, 1, 10));
    });

    test('still accepts ISO-8601 and epoch millis', () {
      expect(parseTwitterDateTime('2025-08-25T14:03:22.000Z'),
          DateTime.utc(2025, 8, 25, 14, 3, 22));
      expect(parseTwitterDateTime('1755000000000')?.isUtc, isTrue);
    });

    test('returns null instead of throwing on garbage', () {
      expect(parseTwitterDateTime(null), isNull);
      expect(parseTwitterDateTime(''), isNull);
      expect(parseTwitterDateTime('not a date'), isNull);
      expect(parseTwitterDateTime('Mon FOO 25 14:03:22 +0000 2025'), isNull);
      // Out-of-range components are normalised by DateTime.utc rather than
      // rejected, so only unparseable shapes can return null here.
      expect(parseTwitterDateTime('tomorrow afternoon'), isNull);
    });
  });

  group('parseTwitterEpochMillis', () {
    test('converts milliseconds since epoch', () {
      expect(parseTwitterEpochMillis(1755000000000)?.toUtc(),
          DateTime.utc(2025, 8, 12, 12));
      expect(parseTwitterEpochMillis('1755000000000')?.toUtc(),
          DateTime.utc(2025, 8, 12, 12));
    });

    test('rejects nonsense', () {
      expect(parseTwitterEpochMillis(null), isNull);
      expect(parseTwitterEpochMillis(0), isNull);
      expect(parseTwitterEpochMillis('abc'), isNull);
    });
  });
}
