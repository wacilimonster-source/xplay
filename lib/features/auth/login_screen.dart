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

              String screenName = (await _controller.runJavaScriptReturningResult(
                      "document.documentElement.outerHTML.match(/\"screen_name\":\"([^\"]+)\"/)?.[1] ?? '';"))
                  .toString();

              if (screenName == '' || screenName == 'null') {
                return;
              }
              screenName = screenName.replaceAll('"', '');
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

              // Fetch rest_id using screenName, retrying across candidate
              // query IDs so an expired ID does not leave restId empty.
              String restId = '';
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
                id: ct0Cookie.value,
                screenName: screenName,
                restId: restId,
                authHeader: json.encode(authHeader),
              );

              await Repository.insertAccount(account);
              ref.read(accountProvider.notifier).login(account);

              if (mounted) {
                Navigator.pop(context, true);
              }
            }
          },
        ),
      )
      ..loadRequest(Uri.parse("https://x.com/i/flow/login"));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('登录 X')),
      body: WebViewWidget(controller: _controller),
    );
  }
}
