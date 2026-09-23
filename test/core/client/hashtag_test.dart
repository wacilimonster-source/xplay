import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// Ad-hoc probe for whether a specific GraphQL operation id is still alive
/// (404 = rotated away, 403 = blocked). It is not an assertion-based test and it
/// needs a live network + valid cookies, so it is skipped by default; run it
/// manually when investigating expired query ids.
void main() {
  test('SearchTimeline operation id reachability probe', () async {
    final oldUri = Uri.https(
        'x.com', '/i/api/graphql/Bcw3RzK-PatNAmbnw54hFw/SearchTimeline');
    final newUri = Uri.https(
        'x.com', '/i/api/graphql/R0u1RWRf748KzyGBXvOYRA/SearchTimeline');

    final oldRes = await http.get(oldUri);
    final newRes = await http.get(newUri);
    // ignore: avoid_print
    debugPrint('Old ID Status: ${oldRes.statusCode}  New ID Status: ${newRes.statusCode}');
  }, skip: 'Live network probe, not an assertion. Run manually when needed.');
}
