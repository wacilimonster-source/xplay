import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_cookie_manager_plus/webview_cookie_manager_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/client/account_provider.dart';
import '../../core/client/query_id_resolver.dart';
import '../../core/client/x_api_constants.dart';
import '../../core/database/entities.dart';
import '../../core/database/repository.dart';
import '../../core/client/twitter_client.dart';
import '../../core/utils/app_logger.dart';

class LoginScreen extends ConsumerStatefulWidget {
  static const homeUrl = 'https://x.com/home';

  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  late final WebViewController _controller;
  final _cookieManager = WebviewCookieManager();
  bool _userFound = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(xMobileUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) async {
            if (url == LoginScreen.homeUrl) {
              if (_userFound) return;

              String screenName = _jsResultToString(
                  await _controller.runJavaScriptReturningResult(
                      "document.documentElement.outerHTML.match(/\"screen_name\":\"([^\"]+)\"/)?.[1] ?? '';"));

              if (screenName.isEmpty) {
                return;
              }
              _userFound = true;

              final cookies =
                  await _cookieManager.getCookies(LoginScreen.homeUrl);
              final ct0Cookie =
                  cookies.where((c) => c.name == 'ct0').firstOrNull;
              if (ct0Cookie == null) {
                _userFound = false;
                AppLogger.log('XFLOW: Login failed: ct0 cookie not found');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('登录态不完整，请重试')));
                }
                return;
              }

              final authHeader = {
                "Cookie": cookies
                    .where((c) => ['guest_id', 'gt', 'att', 'auth_token', 'ct0']
                        .contains(c.name))
                    .map((c) => '${c.name}=${c.value}')
                    .join(";"),
                "authorization": xBearerToken,
                "x-csrf-token": ct0Cookie.value,
              };

              // Fetch rest_id, preferring what the session itself reports.
              //
              // The first `screen_name` in the /home HTML is not guaranteed to
              // be the signed-in user (embedded timeline data can appear
              // earlier), which used to store a stranger's handle + rest id and
              // then sync *their* follow list into this app's subscriptions.
              String restId = '';
              final session = await _fetchSessionUser(authHeader);
              if (session != null) {
                if (session.screenName.isNotEmpty) {
                  screenName = session.screenName;
                }
                restId = session.restId;
                AppLogger.log(
                    'XFLOW: Login identity from session: @$screenName ($restId)');
              }

              if (restId.isEmpty) {
                final attemptPaths =
                    QueryIdResolver.candidatePaths('UserByScreenName');
                for (final path in attemptPaths) {
                  final profileUri = Uri.https('x.com', '/i/api$path', {
                    'variables': jsonEncode({
                      'screen_name': screenName,
                      'withHighlightedLabel': true,
                      'withSafetyModeUserFields': true,
                      'withSuperFollowsUserFields': true
                    }),
                    'features': jsonEncode(TwitterClient.defaultFeatures)
                  });

                  try {
                    final profileRes = await http.get(profileUri, headers: {
                      ...authHeader,
                      'User-Agent': xMobileUserAgent,
                      'Content-Type': 'application/json',
                    });
                    if (profileRes.statusCode != 200) {
                      AppLogger.log(
                          'XFLOW: Login profile fetch status ${profileRes.statusCode} for $path');
                      continue;
                    }
                    final profileData = json.decode(profileRes.body);
                    final userResult = profileData['data']?['user']?['result'];
                    if (userResult != null) {
                      restId = userResult['rest_id'] ?? '';
                    }
                    if (restId.isNotEmpty) break;
                  } catch (e) {
                    AppLogger.log('XFLOW: Login profile fetch error $path: $e');
                  }
                }
              }

              if (restId.isEmpty) {
                _userFound = false;
                AppLogger.log(
                    'XFLOW: Login failed: could not resolve rest_id for @$screenName');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('登录失败，无法获取账号信息，请重试')));
                }
                return;
              }

              final account = Account(
                // Stable primary key: ct0 rotates on every login, so keying by
                // it inserted a new row each time and the app later signed back
                // in with the oldest (expired) stored session.
                id: restId,
                screenName: screenName,
                restId: restId,
                authHeader: json.encode(authHeader),
              );

              await Repository.replaceAccount(account);
              ref.read(accountProvider.notifier).login(account);
              // Fresh session: drop any 429 cooldown / chunk rotation learned
              // under the previous account.
              TwitterClient.clearCooldowns();
              TwitterClient.resetSubscriptionRotation();

              if (mounted) {
                Navigator.pop(context, true);
              }
            }
          },
        ),
      )
      ..loadRequest(Uri.parse("https://x.com/i/flow/login"));
  }

  /// Android's `runJavaScriptReturningResult` hands back the *JSON encoded*
  /// value, so an empty JS string arrives as the two characters `""`. The old
  /// code compared `screenName == ''` *before* stripping the quotes, so that
  /// guard never fired and an empty handle was used for the profile lookup.
  static String _jsResultToString(Object? raw) {
    var text = raw?.toString() ?? '';
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1);
    }
    text = text.replaceAll('"', '').trim();
    if (text == 'null' || text == 'undefined') return '';
    return text;
  }

  /// Asks the signed-in session who it is, instead of trusting the first
  /// `screen_name` found in the /home markup.
  Future<SessionUser?> _fetchSessionUser(
      Map<String, String> authHeader) async {
    try {
      final uri = Uri.https(
          'x.com', '/i/api/1.1/account/verify_credentials.json', {
        'include_entities': 'false',
        'skip_status': 'true',
        'include_email': 'false',
      });
      final res = await http.get(uri, headers: {
        ...authHeader,
        'User-Agent': xMobileUserAgent,
        'x-twitter-active-user': 'yes',
        'x-twitter-client-language': 'en',
        'x-twitter-auth-type': 'OAuth2Session',
      }).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        AppLogger.log('XFLOW: verify_credentials status ${res.statusCode}');
        return null;
      }
      final data = json.decode(utf8.decode(res.bodyBytes));
      if (data is! Map<String, dynamic>) return null;
      final name = data['screen_name']?.toString() ?? '';
      final id = data['id_str']?.toString() ?? data['id']?.toString() ?? '';
      if (name.isEmpty || id.isEmpty) return null;
      return (screenName: name, restId: id);
    } catch (e) {
      AppLogger.log('XFLOW: verify_credentials failed: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('登录 X')),
      body: WebViewWidget(controller: _controller),
    );
  }
}

/// A logged-in identity: handle + numeric rest id.
typedef SessionUser = ({String screenName, String restId});
