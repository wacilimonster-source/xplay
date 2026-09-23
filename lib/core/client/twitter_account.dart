import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:ffcache/ffcache.dart';
import 'x_api_constants.dart';
import 'transaction_id_service.dart';
import 'x_xp_forwarded_for.dart';
import '../database/entities.dart';
import '../database/repository.dart';
import '../utils/app_logger.dart';

class TwitterAccount {
  /// One client for the whole app: the top-level `http.get`/`http.post` helpers
  /// build and close a client per call, so every request paid a fresh TCP+TLS
  /// handshake even though it hit the same host.
  static final http.Client _client = http.Client();

  static Account? _currentAccount;
  static final FFCache _cache = FFCache();

  // When the third-party txId generator is down or returns garbage, stop
  // hammering it: every failed call costs up to 2s per request. Back off
  // for a while instead and send the request without the header (X does
  // not currently require it).
  static DateTime? _txIdRemoteCooldownUntil;
  static const Duration _txIdRemoteCooldown = Duration(seconds: 60);

  static Account? get currentAccount => _currentAccount;

  static Future<void> init() async {
    final accounts = await Repository.getAccounts();
    if (accounts.isNotEmpty) {
      _currentAccount = accounts.first;
    }
  }

  static bool hasAccountAvailable() {
    return _currentAccount != null;
  }

  /// md5 of the request, scoped to the signed-in account: without the scope a
  /// re-login or logout could serve the previous account's cached response for
  /// the remainder of its TTL.
  static String _getCacheKey(Uri uri) {
    final owner = _currentAccount?.restId ?? 'anon';
    return md5
        .convert(utf8.encode('$owner|${uri.toString()}'))
        .toString();
  }

  /// Keys written during this session, so [logout] can drop them (ffcache has
  /// no clear-all).
  static final Set<String> _sessionCacheKeys = {};

  static String compactForLog(Object? value, {int? maxLength}) {
    if (value == null) return 'null';
    final flattened = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (maxLength == null || flattened.length <= maxLength) {
      return flattened;
    }
    return '${flattened.substring(0, maxLength).trimRight()}...';
  }

  static Object? _decodeLogValue(String value) {
    String decoded;
    try {
      decoded = Uri.decodeQueryComponent(value);
    } catch (_) {
      // queryParameters are already decoded once; a second decode can fail
      // when the value legitimately contains a stray '%'. Never let logging
      // break an otherwise valid request.
      decoded = value;
    }
    try {
      return jsonDecode(decoded);
    } catch (_) {
      return decoded;
    }
  }

  static String formatUriForLog(Uri uri) {
    if (uri.query.isEmpty) return uri.path;
    final params = <String, Object?>{};
    for (final entry in uri.queryParameters.entries) {
      params[entry.key] = _decodeLogValue(entry.value);
    }
    return '${uri.path} params=${compactForLog(params)}';
  }

  static String formatTransactionIdForLog(String? transactionId) {
    if (transactionId == null || transactionId.isEmpty) {
      return 'missing';
    }
    return compactForLog(transactionId);
  }

  static String _summarizeRequest(Uri uri, String method, Object? body) {
    final query = uri.query.isEmpty ? '' : ' ${formatUriForLog(uri)}';
    final bodySummary = body == null ? '' : ' body=${compactForLog(body)}';
    return '$method$query$bodySummary';
  }

  static Future<http.Response> fetch(Uri uri,
      {String method = 'GET',
      Object? body,
      Map<String, String>? headers,
      Duration? cacheDuration,
      Duration timeout = const Duration(seconds: 15)}) async {
    // Resolve the account first: the response cache key is scoped by it.
    if (_currentAccount == null) {
      await init();
    }

    final requestSummary = _summarizeRequest(uri, method, body);
    final cacheKey = _getCacheKey(uri);
    if (method == 'GET' && cacheDuration != null) {
      final cachedBody = await _cache.getString(cacheKey);
      if (cachedBody != null) {
        AppLogger.log(
            'HTTP cache hit: $requestSummary bytes=${cachedBody.length}');
        return http.Response(cachedBody, 200, headers: {
          'content-type': 'application/json; charset=utf-8',
        });
      }
      AppLogger.log(
          'HTTP cache miss: $requestSummary ttl=${cacheDuration.inMinutes}m');
    }

    if (_currentAccount == null) {
      await init();
    }

    final combinedHeaders = <String, String>{
      'accept': '*/*',
      'accept-language': 'en-US,en;q=0.9',
      'authorization': xBearerToken,
      'cache-control': 'no-cache',
      'content-type': 'application/json',
      'pragma': 'no-cache',
      'referer': 'https://x.com',
      'origin': 'https://x.com',
      'user-agent': xMobileUserAgent,
      'x-twitter-active-user': 'yes',
      'x-twitter-client-language': 'en',
      'x-twitter-auth-type': 'OAuth2Session',
      ...?headers,
    };

    if (_currentAccount != null) {
      combinedHeaders.addAll(_authHeadersOf(_currentAccount!));
    }

    // X requires the CSRF token (ct0 cookie) on mutation requests (POST).
    // Add it whenever available; harmless on GET.
    final ct0 = _ct0FromAccount();
    if (ct0 != null) {
      combinedHeaders['x-csrf-token'] = ct0;
    }

    // X requires x-xp-forwarded-for on SearchTimeline/Followers since 2026.
    // The AES key is derived from the session's guest_id cookie.
    String? xpff;
    try {
      final guestId = _guestIdFromAccount();
      xpff = guestId == null ? null : XpForwardedFor.generate(guestId: guestId);
      if (xpff != null) {
        combinedHeaders['x-xp-forwarded-for'] = xpff;
      }
    } catch (e) {
      debugPrint('Error generating x-xp-forwarded-for: $e');
    }

    // Try to get x-client-transaction-id
    String? transactionId;
    String txIdStatus = 'missing';
    try {
      transactionId = await TransactionIdService.instance.generateForRequest(
        uri.path,
        method: method,
      );
      if (transactionId != null) {
        combinedHeaders['x-client-transaction-id'] = transactionId;
        txIdStatus = 'local:${formatTransactionIdForLog(transactionId)}';
      } else if (_txIdRemoteCooldownUntil == null ||
          DateTime.now().isAfter(_txIdRemoteCooldownUntil!)) {
        final transactionUri = Uri.http('x-client-transaction-id-generator.xyz',
            '/generate-x-client-transaction-id', {'path': uri.path});
        try {
          final transactionResponse = await _client
              .get(transactionUri)
              .timeout(const Duration(seconds: 2));
          if (transactionResponse.statusCode == 200) {
            transactionId =
                jsonDecode(transactionResponse.body)['x-client-transaction-id'];
            if (transactionId != null) {
              combinedHeaders['x-client-transaction-id'] = transactionId;
              txIdStatus = 'fallback:${formatTransactionIdForLog(transactionId)}';
              _txIdRemoteCooldownUntil = null;
            } else {
              // A 200 that carries no id is just as useless as an error: cool
              // down, otherwise every single request pays this round trip.
              txIdStatus = 'missing:null-response-field';
              _txIdRemoteCooldownUntil =
                  DateTime.now().add(_txIdRemoteCooldown);
            }
          } else {
            txIdStatus =
                'missing:generator-status-${transactionResponse.statusCode}';
            _txIdRemoteCooldownUntil =
                DateTime.now().add(_txIdRemoteCooldown);
          }
        } catch (e) {
          _txIdRemoteCooldownUntil = DateTime.now().add(_txIdRemoteCooldown);
          txIdStatus = 'missing:error:${e.runtimeType}';
        }
      } else {
        txIdStatus = 'missing:remote-cooldown';
      }
    } catch (e) {
      txIdStatus = 'missing:error:${e.runtimeType}';
      debugPrint('Error generating x-client-transaction-id: $e');
    }

    AppLogger.log(
        'HTTP request start: $requestSummary account=${_currentAccount?.screenName ?? 'none'} txId=$txIdStatus xpff=${xpff == null ? 'missing' : 'ok'}');
    final stopwatch = Stopwatch()..start();
    final http.Response response;
    if (method == 'POST') {
      response = await _client
          .post(uri, headers: combinedHeaders, body: body)
          .timeout(timeout);
    } else {
      response =
          await _client.get(uri, headers: combinedHeaders).timeout(timeout);
    }
    stopwatch.stop();
    AppLogger.log(
        'HTTP request end: $requestSummary status=${response.statusCode} elapsedMs=${stopwatch.elapsedMilliseconds} bytes=${response.bodyBytes.length}');

    if (response.statusCode == 403) {
      // X rejected the request; whatever transaction id we just sent is not
      // reusable, so drop the cache instead of replaying it for 20 seconds.
      TransactionIdService.instance.invalidateTxIdCache();
    }

    if (response.statusCode == 200) {
      // Force UTF-8 decoding for the body string to avoid mangling and caching issues
      final decodedBody = utf8.decode(response.bodyBytes);
      if (method == 'GET' && cacheDuration != null) {
        await _cache.setStringWithTimeout(cacheKey, decodedBody, cacheDuration);
        _sessionCacheKeys.add(cacheKey);
      }
      return http.Response(decodedBody, 200, headers: {
        ...response.headers,
        'content-type': 'application/json; charset=utf-8',
      });
    }
    return response;
  }

  /// Stored per-account headers (Cookie + authorization). A corrupt blob used to
  /// throw out of [fetch] and surface as "未找到媒体内容" with no hint that the
  /// saved session is broken; now it is logged and treated as "not signed in".
  static Map<String, String> _authHeadersOf(Account account) {
    try {
      return Map<String, String>.from(json.decode(account.authHeader));
    } catch (e) {
      AppLogger.log(
          'XFLOW: stored authHeader for ${account.screenName} is unreadable: $e');
      return const {};
    }
  }

  static String? _cookieValue(String name) {
    final account = _currentAccount;
    if (account == null) return null;
    final cookie = _authHeadersOf(account)['Cookie'];
    if (cookie == null) return null;
    final match =
        RegExp('(?:^|;\\s*)${RegExp.escape(name)}=([^;]+)').firstMatch(cookie);
    return match?.group(1);
  }

  /// True when a stored, readable session exists (used by the empty-feed UI).
  static bool hasUsableSession() {
    final account = _currentAccount;
    if (account == null) return false;
    return _authHeadersOf(account)['Cookie'] != null;
  }

  static String? _guestIdFromAccount() => _cookieValue('guest_id');

  static String? _ct0FromAccount() => _cookieValue('ct0');

  static void setCurrentAccount(Account account) {
    _currentAccount = account;
  }

  static Future<void> logout() async {
    final db = await Repository.database;
    await db.delete(tableAccounts);
    _currentAccount = null;
    // Cached responses (timelines, follow lists) belong to the account that is
    // being signed out of; leaving them behind shows the old user's data.
    final keys = _sessionCacheKeys.toList();
    _sessionCacheKeys.clear();
    for (final key in keys) {
      try {
        await _cache.remove(key);
      } catch (_) {}
    }
  }
}
