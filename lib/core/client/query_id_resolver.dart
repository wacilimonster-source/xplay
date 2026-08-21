import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:http/http.dart' as http;

import '../utils/app_logger.dart';

/// Resolves X/Twitter GraphQL query IDs at runtime.
///
/// X rotates these IDs periodically and no longer ships them in the static
/// web bundle, so hardcoding them (as the original repo did) breaks the app
/// once they expire (media stops loading with HTTP 404).
///
/// Strategy:
///  1. Bundled fallback defaults (last-known community values) so the app works
///     out of the box even offline.
///  2. Runtime capture: the logged-in [TransactionIdWebViewHost] WebView hooks
///     fetch/XHR and records the real `/i/api/graphql/{id}/{op}` URLs that
///     x.com's own code generates. These are persisted and reused.
///  3. (Optional) remote JSON override — set [remoteUrl] to a JSON map of
///     `{ "Operation": "queryId" }` and it will be merged on init.
class QueryIdResolver {
  QueryIdResolver._();

  /// Bundled fallback IDs. Values here are best-effort community snapshots and
  /// may be expired; the live WebView capture overrides them when available.
  static final Map<String, String> _bundled = {
    'SearchTimeline': 'GcXk9vN_d1jUfHNqLacXQA',
    'TweetDetail': 'VWFGPVAGkZMGRKGe3GFFnA',
    'HomeTimeline': 'HCosKfLNW1AcOo3la3mMgg',
    'HomeLatestTimeline': 'zhX91JE87mWvfprhYE97xA',
    'Following': 'OLm4oHZBfqWx8jbcEhWoFw',
    'UserByScreenName': 'Gb-d6r0vxPOADdG62OEBpQ',
    'UserTweets': 'eoJ5zbv51Z_KVl81v9PmLQ',
    'MediaTabVideoMixer': 'rAqW5uh6Unfi46lidxFwzA',
    'FavoriteTweet': 'lI07N6Otwv1PhnEgXILM7A',
    'UnfavoriteTweet': 'ZYKSe-w7KEslx3JhSIk5LA',
    'FollowMutation': 'gR6jKoWRvzfqUhTqNJE2Qw',
  };

  static final Map<String, String> _ids = Map.from(_bundled);
  static bool _loaded = false;

  /// Optional remote JSON override URL (a map of operation -> queryId).
  /// Leave null to disable.
  static String? remoteUrl;

  static Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('xflow_query_ids');
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        var count = 0;
        map.forEach((k, v) {
          if (v is String && v.isNotEmpty) {
            _ids[k] = v;
            count++;
          }
        });
        AppLogger.log('XFLOW: Loaded $count persisted query IDs from storage.');
      }
    } catch (e) {
      AppLogger.log('XFLOW: Failed to load persisted query IDs: $e');
    }
    if (remoteUrl != null && remoteUrl!.isNotEmpty) {
      await _fetchRemote();
    }
  }

  static Future<void> _fetchRemote() async {
    try {
      final resp = await http
          .get(Uri.parse(remoteUrl!))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final map = jsonDecode(resp.body) as Map<String, dynamic>;
        var count = 0;
        map.forEach((k, v) {
          if (v is String && v.isNotEmpty) {
            _ids[k] = v;
            count++;
          }
        });
        AppLogger.log('XFLOW: Merged $count query IDs from remote source.');
        await _persist();
      }
    } catch (e) {
      AppLogger.log('XFLOW: Remote query-id fetch failed: $e');
    }
  }

  /// Known alternate IDs per operation. Tried (in order) after the primary
  /// when a request 404s, so a single expired primary does not kill the call.
  /// Sourced from community clients (go-twitter / twikit / twscrape / ylw1997).
  static final Map<String, List<String>> _alternates = {
    'SearchTimeline': [
      'gkjsKepM6gl_HmFWoWKfgg',
      'GcXk9vN_d1jUfHNqLacXQA',
      'lZ0GCEojmtQfiUQa5oJSEw',
      'XN_HccZ9SU-miQVvwTAlFQ',
      '6AAys3t42mosm_yTI_QENg',
      'BGd0T_j7oVwlW5U79tO_0A',
    ],
    'TweetDetail': [
      '6I7Hm635Q6ftv69L8VrSeQ',
      'VWFGPVAGkZMGRKGe3GFFnA',
      'U0HTv-bAWTBYylwEMT7x5A',
      'BbmLpxKh8rX8LNe2LhVujA',
      '559hs_YZNV4IgA3Z6zIIuw',
    ],
    'HomeTimeline': [
      'HCosKfLNW1AcOo3la3mMgg',
      '-X_hcgQzmHGl29-UXxz4sw',
      'edseUwk9sP5Phz__9TIRnA',
    ],
    'HomeLatestTimeline': [
      'zhX91JE87mWvfprhYE97xA',
      'iOEZpOdfekFsxSlPQCQtPg',
    ],
    'Following': [
      'OLm4oHZBfqWx8jbcEhWoFw',
      '2vUj-_Ek-UmBVDNtd8OnQA',
      '8cyc0OKedV_XD62fBjzxUw',
      'b8XpwALENnJdFSHchkK6rw',
    ],
    'UserByScreenName': [
      '-oaLodhGbbnzJBACb1kk2Q',
      'Gb-d6r0vxPOADdG62OEBpQ',
      'IGgvgiOx4QZndDHuD3x9TQ',
      'G3KGOASz96M-Qu0nwmGXNg',
    ],
    'UserTweets': [
      '9rys0A7w1EyqVd2ME0QCJg',
      'eoJ5zbv51Z_KVl81v9PmLQ',
      'FOlovQsiHGDls3c0Q_HaSQ',
      'VgitpdpNZ-RUIp5D1Z_D-A',
    ],
    'MediaTabVideoMixer': [
      'rAqW5uh6Unfi46lidxFwzA',
      'kR-S7-PwOqpnDegF-Yn5Aw',
    ],
    'FavoriteTweet': ['lI07N6Otwv1PhnEgXILM7A'],
    'UnfavoriteTweet': ['ZYKSe-w7KEslx3JhSIk5LA'],
    'FollowMutation': [
      'gR6jKoWRvzfqUhTqNJE2Qw',
      's7Fsr91nXJbwYcMTZ9Gzqw',
      '1tXuAKRpcVzsxGuQ0UzZpg',
    ],
  };

  /// Returns the GraphQL path for [op], e.g. `/graphql/<id>/SearchTimeline`.
  /// Falls back to [fallbackOp] then the bundled default if unknown.
  static String pathFor(String op, [String? fallbackOp]) {
    final id = _ids[op] ?? (fallbackOp != null ? _ids[fallbackOp] : null) ?? _bundled[op];
    return '/graphql/$id/$op';
  }

  /// Candidate paths for [op], primary first, then known alternates.
  /// Used to retry on HTTP 404 without waiting for a live capture.
  static List<String> candidatePaths(String op) {
    final primary = _ids[op] ?? _bundled[op];
    final list = <String>['/graphql/$primary/$op'];
    for (final alt in (_alternates[op] ?? [])) {
      if (alt != primary) list.add('/graphql/$alt/$op');
    }
    return list;
  }

  static String? idFor(String op) => _ids[op];

  static Map<String, String> get all => Map.unmodifiable(_ids);

  static Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('xflow_query_ids', jsonEncode(_ids));
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // WebView live capture
  // ---------------------------------------------------------------------------

  /// Installs a fetch/XHR hook in the WebView that records every
  /// `/i/api/graphql/{id}/{op}` URL x.com generates. Safe to call repeatedly.
  static const String captureScript = r'''
  (function () {
    if (window.__xflowQidHook) return 'already';
    try {
      window.__xflowQids = window.__xflowQids || {};
      function record(u) {
        try {
          var s = (u && u.url) ? u.url : (typeof u === 'string' ? u : (u && u.toString ? u.toString() : ''));
          var m = s.match(/\/i\/api\/graphql\/([A-Za-z0-9_-]{15,32})\/([A-Za-z0-9_]+)/);
          if (m) window.__xflowQids[m[2]] = m[1];
        } catch (e) {}
      }
      var fo = window.fetch;
      window.fetch = function () {
        try { record(arguments[0]); } catch (e) {}
        return fo.apply(this, arguments);
      };
      var XO = window.XMLHttpRequest;
      if (XO) {
        window.XMLHttpRequest = function () {
          var x = new XO();
          var os = x.open;
          x.open = function () { try { record(arguments[1]); } catch (e) {} return os.apply(x, arguments); };
          return x;
        };
      }
      window.__xflowQidHook = true;
      return 'installed';
    } catch (e) { return 'error:' + e; }
  })();
  ''';

  /// Reads the currently-captured IDs from the WebView.
  static Future<Map<String, String>> readCaptured(
      WebViewController controller) async {
    try {
      final raw = await controller.runJavaScriptReturningResult(
          'JSON.stringify(window.__xflowQids || {})');
      return _parseJsMap(raw);
    } catch (e) {
      AppLogger.log('XFLOW: readCaptured failed: $e');
      return {};
    }
  }

  /// Installs the hook and immediately merges whatever x.com has already
  /// generated (e.g. the home timeline). Returns the number of ops captured.
  static Future<int> captureFromWebView(WebViewController controller) async {
    try {
      await controller.runJavaScript(captureScript);
      await Future.delayed(const Duration(seconds: 3));
      final map = await readCaptured(controller);
      if (map.isNotEmpty) {
        _ids.addAll(map);
        await _persist();
        AppLogger.log('XFLOW: Captured ${map.length} live query IDs: '
            '${map.keys.join(', ')}');
      } else {
        AppLogger.log('XFLOW: captureFromWebView: no IDs captured from this page');
      }
      return map.length;
    } catch (e) {
      AppLogger.log('XFLOW: captureFromWebView failed: $e');
      return 0;
    }
  }

  static Map<String, String> _parseJsMap(dynamic raw) {
    if (raw == null) return {};
    var s = raw.toString();
    if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
      s = s.substring(1, s.length - 1);
    }
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }
}
