import 'package:flutter_test/flutter_test.dart';
import 'package:xplay/core/client/query_id_resolver.dart';

void main() {
  group('Query ID resolver API parity', () {
    test('provides SearchTimeline candidates with a stable operation suffix', () {
      final paths = QueryIdResolver.candidatePaths('SearchTimeline');

      expect(paths, isNotEmpty);
      expect(paths.first, endsWith('/SearchTimeline'));
      expect(paths.toSet().length, paths.length);
    });
  });
}
