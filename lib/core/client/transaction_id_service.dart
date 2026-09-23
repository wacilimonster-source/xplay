import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../features/auth/login_screen.dart';
import '../../features/feed/feed_provider.dart';
import '../utils/app_logger.dart';
import 'account_provider.dart';
import 'query_id_resolver.dart';
import 'x_api_constants.dart';

class TransactionIdService {
  TransactionIdService._();

  static final TransactionIdService instance = TransactionIdService._();

  WebViewController? _controller;
  bool _isReady = false;
  bool _scriptInstalled = false;

  /// Reuses a generated id for repeated calls to the same `method + path`.
  ///
  /// The embedded generator packs a *second-granularity* timestamp
  /// (`Math.floor((Date.now() - 1682924400000) / 1e3)`) into the token, so the
  /// safe reuse window is seconds, not minutes: a 5-minute cache (as suggested
  /// in the optimisation report) would send stale ids and get 403s. 20s still
  /// collapses bursts such as `fetchMore`, which hits the same SearchTimeline
  /// path repeatedly within a few seconds.
  final Map<String, _CachedTxId> _txIdCache = {};
  static const Duration _txIdTtl = Duration(seconds: 20);
  static const int _txIdCacheLimit = 64;

  void attachController(WebViewController controller) {
    _controller = controller;
    _scriptInstalled = false;
  }

  void markReady(bool ready) {
    _isReady = ready;
    if (!ready) {
      _scriptInstalled = false;
      _txIdCache.clear();
    }
  }

  /// Drops cached ids. Called when X rejects a request, so a token that turned
  /// out to be unusable is never replayed.
  void invalidateTxIdCache() => _txIdCache.clear();

  /// Every x.com page load resets the JS context, wiping the injected
  /// generator. Re-install it (idempotent) so the local channel survives
  /// navigation, otherwise [_scriptInstalled] stays true and the local
  /// channel silently dies for the whole session.
  Future<void> reinstallScriptOnPageLoaded(WebViewController controller) async {
    try {
      await controller.runJavaScript(_transactionIdGeneratorScript);
      _scriptInstalled = true;
      // New page context means a new fingerprint; previously issued ids from the
      // old context must not be replayed.
      _txIdCache.clear();
    } catch (_) {
      _scriptInstalled = false;
    }
  }

  Future<String?> generateForRequest(String path,
      {String method = 'GET'}) async {
    final controller = _controller;
    if (controller == null || !_isReady) {
      return null;
    }

    final cacheKey = '$method:$path';
    final now = DateTime.now();
    final cached = _txIdCache[cacheKey];
    if (cached != null) {
      if (now.isBefore(cached.expiresAt)) return cached.id;
      _txIdCache.remove(cacheKey);
    }

    try {
      await _ensureScriptInstalled(controller);
      final rawResult = await controller.runJavaScriptReturningResult('''
        (async function() {
          return await window.__xflowGenerateTransactionId(
            ${jsonEncode(path)},
            ${jsonEncode(method)}
          );
        })();
      ''');
      final id = normalizeJavaScriptResult(rawResult);
      if (id != null) {
        if (_txIdCache.length >= _txIdCacheLimit) _txIdCache.clear();
        _txIdCache[cacheKey] = _CachedTxId(id, now.add(_txIdTtl));
      }
      return id;
    } catch (e) {
      AppLogger.log('TXID local generation failed: ${e.runtimeType}: $e');
      return null;
    }
  }

  Future<void> _ensureScriptInstalled(WebViewController controller) async {
    if (_scriptInstalled) return;
    await controller.runJavaScript(_transactionIdGeneratorScript);
    _scriptInstalled = true;
  }

  static String? normalizeJavaScriptResult(Object? value) {
    if (value == null) return null;
    final text = value.toString();
    if (text == 'null' || text.isEmpty) return null;
    if (text == '{}' || text == '[object Object]') return null; // Broken fingerprint
    if (text.startsWith('"') && text.endsWith('"') && text.length >= 2) {
      return text.substring(1, text.length - 1);
    }
    return text;
  }

  @visibleForTesting
  static String get embeddedGeneratorScript => _transactionIdGeneratorScript;
}

class TransactionIdWebViewHost extends ConsumerStatefulWidget {
  const TransactionIdWebViewHost({super.key});

  @override
  ConsumerState<TransactionIdWebViewHost> createState() =>
      _TransactionIdWebViewHostState();
}

class _TransactionIdWebViewHostState
    extends ConsumerState<TransactionIdWebViewHost> {
  /// Null when no WebView platform is available (widget tests, or a device
  /// without a WebView provider). Building the controller in that state threw an
  /// assertion that took the whole app down; now the rest of the UI works and
  /// only the transaction-id / query-id capture is unavailable.
  WebViewController? _controllerOrNull;
  WebViewController get _controller => _controllerOrNull!;
  String? _loadedAccountId;
  bool _captureRunning = false;
  bool _captureSatisfied = false;

  @override
  void initState() {
    super.initState();
    try {
      _controllerOrNull = _buildController();
      TransactionIdService.instance.attachController(_controllerOrNull!);
    } catch (e) {
      AppLogger.log('TXID WebView unavailable on this platform: $e');
    }
  }

  WebViewController _buildController() => WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(xMobileUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            // Install the query-ID capture hook BEFORE x.com's JS runs,
            // so we intercept the real GraphQL URLs x.com generates.
            if (url.startsWith('https://x.com/')) {
              _controller.runJavaScript(QueryIdResolver.captureScript)
                  .catchError((_) {});
            }
          },
          onPageFinished: (url) {
            final ready = url.startsWith('https://x.com/');
            TransactionIdService.instance.markReady(ready);
            if (ready) {
              AppLogger.log('TXID WebView ready at $url');
              // Re-install capture hook (in case onPageStarted was too early
              // or the page context was reset) and read whatever was captured.
              _controller.runJavaScript(QueryIdResolver.captureScript)
                  .catchError((_) {});
              // Page load reset the JS context, so the txId generator must be
              // re-installed too, or the local txId channel dies silently.
              TransactionIdService.instance
                  .reinstallScriptOnPageLoaded(_controller);
              _maybeStartQueryIdCapture();
            }
          },
        ),
      );

  /// Once the logged-in WebView is ready, hook its network layer and walk
  /// through a few pages so x.com generates the real (current) GraphQL query
  /// IDs for the operations xflow needs. Captured IDs are persisted and reused.
  void _maybeStartQueryIdCapture() {
    if (_captureRunning) return;
    // Persisted live ids are still fresh (14 days): skip the whole walk. This is
    // the difference between a 20-25s first-run cost on every launch and only on
    // the launches that actually need it.
    if (_captureSatisfied && !QueryIdResolver.needsCapture) return;
    _captureRunning = true;
    _runQueryIdCaptureSequence().whenComplete(() => _captureRunning = false);
  }

  /// Navigates to [url] and polls for the required query ids, returning as soon
  /// as they have all been seen — instead of a fixed 5s + 2s per page.
  Future<void> _captureOnPage(
      WebViewController controller, String url, Duration budget) async {
    try {
      await controller
          .runJavaScript(QueryIdResolver.captureScript)
          .catchError((_) {});
      await controller.loadRequest(Uri.parse(url));
      final deadline = DateTime.now().add(budget);
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 700));
        await QueryIdResolver.captureNow(controller);
        if (QueryIdResolver.isCaptureComplete) return;
      }
    } catch (e) {
      AppLogger.log('XFLOW: query-id capture on $url failed: ${e.runtimeType}');
    }
  }

  Future<void> _runQueryIdCaptureSequence() async {
    final controller = _controllerOrNull;
    if (controller == null) return;
    try {
      final missingBefore = QueryIdResolver.missingRequired().length;
      // Install hook + capture whatever the home timeline already produced.
      await QueryIdResolver.captureFromWebView(controller);
      const supplementPages = <String>[
        'https://x.com/search?q=test&f=live',
        'https://x.com/x',
        'https://x.com/i/bookmarks',
      ];
      for (final page in supplementPages) {
        if (QueryIdResolver.isCaptureComplete) break;
        await _captureOnPage(controller, page, const Duration(seconds: 6));
      }

      final missing = QueryIdResolver.missingRequired();
      _captureSatisfied = missing.isEmpty;
      if (missing.isNotEmpty) {
        AppLogger.log('XFLOW: query-id capture still missing: '
            '${missing.join(', ')} (will retry on next page load)');
      }
      // Return to home so the transaction-id probe keeps working.
      await controller.loadRequest(Uri.parse(LoginScreen.homeUrl));
      AppLogger.log('XFLOW: Query-ID capture sequence complete. '
          'Known ops: ${QueryIdResolver.all.keys.join(', ')}');
      // Only rebuild the feed when this walk actually unlocked new ids, so a
      // routine page load no longer costs a full refetch.
      if (mounted && QueryIdResolver.missingRequired().length < missingBefore) {
        ref.invalidate(feedNotifierProvider);
      }
    } catch (e) {
      AppLogger.log('XFLOW: Query-ID capture sequence failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    if (_controllerOrNull == null) {
      // WebView is unavailable here; skip the capture quietly instead of
      // throwing during the first frame.
      return const SizedBox.shrink();
    }
    if (account == null) {
      TransactionIdService.instance.markReady(false);
      _loadedAccountId = null;
      return const SizedBox.shrink();
    }

    if (_loadedAccountId != account.id) {
      _loadedAccountId = account.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _controller.loadRequest(Uri.parse(LoginScreen.homeUrl));
      });
    }

    return IgnorePointer(
      child: Opacity(
        opacity: 0.01,
        child: SizedBox(
          width: 1,
          height: 1,
          child: WebViewWidget(controller: _controller),
        ),
      ),
    );
  }
}

const String _transactionIdGeneratorScript = r'''
(() => {
  if (window.__xflowGenerateTransactionId) return;

  // Source-aligned port of fa0311/twitter-tid-deobf-fork output/additional2.js.
  const W = () => {
    let Sc;
    let zc;
    let Yc = [];

    const lc = (n) =>
      btoa(Array.from(n).map((n) => String.fromCharCode(n)).join('')).replace(
        /=/g,
        ''
      );

    const Jc = (n, t) => (n && n.getAttribute(t)) || '';

    const hc = (n) => (typeof n === 'string' ? new TextEncoder().encode(n) : n);

    const wc = (n) => crypto.subtle.digest('sha-256', hc(n));

    const pc = (n) => (n < 16 ? '0' : '') + n.toString(16);

    const Fc = (n) =>
      Array.from(n).map((n) => (n.parentElement?.removeChild(n), n));

    const Ac = (n, t, r) => (t ? n ^ r[0] : n);

    const Pc = () => {
      const n = Jc(document.querySelectorAll('[name^=tw]')[0], 'content');
      if (!n) return null;
      return new Uint8Array(atob(n).split('').map((n) => n.charCodeAt(0)));
    };

    const Uc = (n, t) =>
      (Sc =
        Sc ||
        Jc(Fc(document.querySelectorAll(n))[t[5] % 4]?.childNodes?.[0]?.childNodes?.[1], 'd')
          .substring(9)
          .split('C')
          .map((n) =>
            n
              .replace(/[^\d]+/g, ' ')
              .trim()
              .split(' ')
              .map(Number)
          ));

    const Mc = (n, t, r, u) => {
      const c = (n * (r - t)) / 255 + t;
      return u ? Math.floor(c) : c.toFixed(2);
    };

    const yc = (n) => ({
      color: [
        '#' + pc(n[0]) + pc(n[1]) + pc(n[2]),
        '#' + pc(n[3]) + pc(n[4]) + pc(n[5]),
      ],
      transform: ['rotate(0deg)', 'rotate(' + Mc(n[6], 60, 360, true) + 'deg)'],
      easing:
        'cubic-bezier(' +
        Array.from(n.slice(7))
          .map((n, t) => Mc(n, t % 2 ? -1 : 0, 1, false))
          .join() +
        ')',
    });

    const ensureProbe = () => {
      let probe = document.getElementById('__xflow_txid_probe');
      if (!probe) {
        probe = document.createElement('div');
        probe.id = '__xflow_txid_probe';
        probe.style.position = 'absolute';
        probe.style.left = '-9999px';
        probe.style.top = '-9999px';
        probe.style.width = '1px';
        probe.style.height = '1px';
        probe.style.pointerEvents = 'none';
        document.body.appendChild(probe);
      }
      return probe;
    };

    const kn = ensureProbe();
    const On = () => kn.remove();

    const Ic = (n, t, r) => {
      if (!n.animate) return;
      const u = n.animate(yc(t), 4096);
      u.pause();
      u.currentTime = Math.round(r / 10) * 10;
    };

    const Ec = (n) => {
      if (!zc) {
        const an = Uc('.r-0', n);
        if (!an || !an[n[33] % 16]) return null;

        new Promise(() => {
          try {
            const r = new RTCPeerConnection();
            const c = Math.random().toString(36);
            r.createDataChannel(c);
            r.createOffer()
              .then((W) => {
                try {
                  const t = W.sdp || c;
                  Yc = Array.from(hc([t[n[5] % 8] || '4', t[n[8] % 8] || '0']));
                  r.close();
                } catch (_) {}
              })
              .catch(() => 0);
          } catch (_) {}
        }).catch(() => 0);

        Ic(
          kn,
          an[n[33] % 16],
          (n[28] % 16) * (n[28] % 16) * (n[37] % 16)
        );
        const Gn = getComputedStyle(kn);
        zc = Array.from(
          ('' + Gn.color + Gn.transform).matchAll(/([\d.-]+)/g)
        )
          .map((n) => Number(Number(n[0]).toFixed(2)).toString(16))
          .join('')
          .replace(/[.-]/g, '');
        On();
      }
      return zc;
    };

    return async (n, t) => {
      const o = Math.floor((Date.now() - 1682924400000) / 1e3);
      const e = new Uint8Array(new Uint32Array([o]).buffer);
      const f = Pc();
      if (!f) return null;
      const i = Ec(f);
      if (!i) return null;

      return lc(
        new Uint8Array(
          [Math.random() * 256]
            .concat(
              Array.from(f),
              Array.from(e),
              Array.from(
                new Uint8Array(await wc([t, n, o].join('!') + 'obfiowerehiring' + i))
              )
                .slice(0, 16)
                .concat(Yc),
              [3]
            )
            .map(Ac)
        )
      );
    };
  };

  window.__xflowGenerateTransactionId = W();
})();
''';

class _CachedTxId {
  _CachedTxId(this.id, this.expiresAt);
  final String id;
  final DateTime expiresAt;
}
