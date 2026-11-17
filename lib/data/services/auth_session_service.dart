import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/motive_api_models.dart';

/// Manages authentication sessions for both Salesforce FSL and Motive accounts.
///
/// Supports:
/// 1. Standalone Username/Email + Password login for Salesforce FSL and Motive,
///    with automatic background re-authentication whenever a session expires
///    (works identically on Android, Linux, and Windows with zero browser dependency).
/// 2. Multi-organization Motive support (e.g., `HEART` and `Houston Towing`).
/// 3. Optional 1-click session sync from an open desktop browser (Chrome CDP port 9222).
/// 4. Raw cookie/token or `auth_state.json` import as an advanced fallback.
class AuthSessionService {
  static const String _keyFslBaseUrl = 'fsl_base_url';
  static const String _keyFslCookieHeader = 'fsl_cookie_header';
  static const String _keyFslUsername = 'fsl_saved_username';
  static const String _keyFslPassword = 'fsl_saved_password';
  static const String _keyMotiveEmail = 'motive_saved_email';
  static const String _keyMotivePassword = 'motive_saved_password';
  static const String _keyMotiveAccounts = 'motive_account_sessions_v1';

  static const String defaultFslBaseUrl =
      'https://aaa-ace.my.site.com/ACEContractorCommunity';

  String _fslBaseUrl = defaultFslBaseUrl;
  String _fslCookieHeader = '';
  String _fslSavedUsername = '';
  String _fslSavedPassword = '';
  String _motiveSavedEmail = '';
  String _motiveSavedPassword = '';
  List<MotiveAccountSession> _motiveAccounts = const [];

  String get fslBaseUrl => _fslBaseUrl;
  String get fslCookieHeader => _fslCookieHeader;
  String get fslSavedUsername => _fslSavedUsername;
  bool get hasSavedFslCredentials =>
      _fslSavedUsername.trim().isNotEmpty && _fslSavedPassword.isNotEmpty;
  String get motiveSavedEmail => _motiveSavedEmail;
  bool get hasSavedMotiveCredentials =>
      _motiveSavedEmail.trim().isNotEmpty && _motiveSavedPassword.isNotEmpty;
  List<MotiveAccountSession> get motiveAccounts =>
      List.unmodifiable(_motiveAccounts);

  bool get hasFslSession =>
      _fslCookieHeader.trim().isNotEmpty || hasSavedFslCredentials;
  bool get hasMotiveSession =>
      _motiveAccounts.any((a) => a.authToken.trim().isNotEmpty);

  /// Normalizes verbose legal company names from Motive into clean display names.
  static String normalizeMotiveOrgName(String rawName, String orgId) {
    final trimmed = rawName.trim();
    final upper = trimmed.toUpperCase();
    if (upper.contains('HOUSTON EMERGENCY AUTO RESCUE') || upper == 'HEART') {
      return 'HEART';
    }
    if (upper.contains('HOUSTON TOWING') || upper == 'HT') {
      return 'Houston Towing';
    }
    return trimmed.isNotEmpty ? trimmed : 'Motive Fleet';
  }

  Future<void> loadSavedSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final savedBase = prefs.getString(_keyFslBaseUrl) ?? defaultFslBaseUrl;
    _fslBaseUrl = savedBase.contains('://my.site.com')
        ? defaultFslBaseUrl
        : savedBase;
    _fslCookieHeader = prefs.getString(_keyFslCookieHeader) ?? '';
    _fslSavedUsername = prefs.getString(_keyFslUsername) ?? '';
    _fslSavedPassword = prefs.getString(_keyFslPassword) ?? '';
    _motiveSavedEmail = prefs.getString(_keyMotiveEmail) ?? '';
    _motiveSavedPassword = prefs.getString(_keyMotivePassword) ?? '';

    final rawAccounts = prefs.getString(_keyMotiveAccounts);
    if (rawAccounts != null && rawAccounts.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawAccounts);
        if (decoded is List) {
          _motiveAccounts = decoded
              .whereType<Map<String, dynamic>>()
              .map(MotiveAccountSession.fromJson)
              .where((a) => a.authToken.isNotEmpty)
              .map(
                (a) => MotiveAccountSession(
                  organizationId: a.organizationId,
                  organizationName: normalizeMotiveOrgName(
                    a.organizationName,
                    a.organizationId,
                  ),
                  authToken: a.authToken,
                ),
              )
              .toList();
        }
      } catch (_) {
        _motiveAccounts = const [];
      }
    }

    // Auto-import any local motive_auth.json / motive_org2_auth.json files if present
    await _importLocalMotiveAuthFilesIfPresent();

    // Ensure normalized names are persisted
    if (_motiveAccounts.isNotEmpty) {
      await saveMotiveAccounts(_motiveAccounts);
    }
  }

  Future<void> _importLocalMotiveAuthFilesIfPresent() async {
    if (Platform.isAndroid || Platform.isIOS) return;
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
    final candidateDirs = <String>[
      if (home.isNotEmpty)
        p.join(home, 'Projects', 'motive-safety-console', 'data'),
      'data',
    ];
    for (final dirPath in candidateDirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      for (final fileName in const [
        'motive_auth.json',
        'motive_org2_auth.json',
      ]) {
        final file = File(p.join(dir.path, fileName));
        if (!file.existsSync()) continue;
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map<String, dynamic>) {
            final token = (decoded['token'] ?? '').toString().trim();
            final cid = (decoded['company_id'] ?? '').toString().trim();
            final cname = (decoded['company_name'] ?? '').toString().trim();
            if (token.isNotEmpty) {
              final alreadyHas = _motiveAccounts.any(
                (a) =>
                    a.authToken == token ||
                    (cid.isNotEmpty && a.organizationId == cid),
              );
              if (!alreadyHas) {
                await upsertMotiveAccount(
                  MotiveAccountSession(
                    organizationId: cid,
                    organizationName: normalizeMotiveOrgName(cname, cid),
                    authToken: token,
                  ),
                );
              }
            }
          }
        } catch (_) {}
      }
    }
  }

  /// Automatically refreshes the Salesforce FSL session without needing a browser:
  /// 1. First attempts direct HTTP re-login using saved FSL username + password
  ///    (works on Android, Linux, and Windows completely standalone).
  /// 2. Falls back to open browser CDP sync on Desktop only if no credentials are saved.
  Future<({bool refreshed, String message})>
  refreshFslSessionAutomatically() async {
    if (hasSavedFslCredentials) {
      try {
        await loginFslWithCredentials(
          username: _fslSavedUsername,
          password: _fslSavedPassword,
          baseUrl: _fslBaseUrl,
        );
        return (
          refreshed: true,
          message: 'Auto-refreshed FSL session via saved credentials.',
        );
      } catch (e) {
        // Fall through to CDP check on desktop if direct login encountered an issue
      }
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      final cdp = await syncFromOpenBrowserCdp();
      if (cdp.fslSynced) {
        return (refreshed: true, message: cdp.message);
      }
    }

    return (
      refreshed: false,
      message: 'FSL session expired. Sign in once in Connections to enable automatic background refresh.',
    );
  }

  /// Signs in to the Salesforce FSL Contractor Community using standard
  /// [username] and [password] credentials, and saves them for automatic
  /// standalone session renewal when cookies expire.
  Future<void> loginFslWithCredentials({
    required String username,
    required String password,
    String? baseUrl,
  }) async {
    final cleanUser = username.trim();
    if (cleanUser.isEmpty || password.isEmpty) {
      throw Exception('Please enter both username and password.');
    }

    final targetBase = (baseUrl != null && baseUrl.trim().isNotEmpty)
        ? baseUrl.trim().replaceAll(RegExp(r'/+$'), '')
        : _fslBaseUrl;
    final loginUri = Uri.parse('$targetBase/login');
    final cookieJar = <String, String>{};

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent =
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';

    void collectCookies(HttpClientResponse response) {
      for (final c in response.cookies) {
        if (c.value.isNotEmpty && c.value != 'deleted') {
          cookieJar[c.name] = c.value;
        }
      }
    }

    String buildCookieHeader() =>
        cookieJar.entries.map((e) => '${e.key}=${e.value}').join('; ');

    try {
      // 1. Initial GET to /login to seed session/CSRF cookies
      final initReq = await client.getUrl(loginUri);
      initReq.followRedirects = false;
      final initRes = await initReq.close();
      await initRes.drain<void>();
      collectCookies(initRes);

      // 2. POST credentials to /ACEContractorCommunity/login
      final startPath = Uri.parse(targetBase).path;
      final formBody = <String, String>{
        'passwordShown': 'true',
        'un': cleanUser,
        'username': cleanUser,
        'pw': password,
        'hasRememberUn': 'true',
        'rememberUn': 'on',
        'useSecure': 'true',
        'lt': 'standard',
        'display': 'page',
        'Login': 'Log In',
        'startURL': '$startPath/apex/FSL__vf001_ServiceExpert',
      };
      final encodedForm = formBody.entries
          .map(
            (e) =>
                '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&');

      final postReq = await client.postUrl(loginUri);
      postReq.followRedirects = false;
      postReq.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/x-www-form-urlencoded',
      );
      if (cookieJar.isNotEmpty) {
        postReq.headers.set(HttpHeaders.cookieHeader, buildCookieHeader());
      }
      postReq.headers.set(HttpHeaders.refererHeader, loginUri.toString());
      postReq.add(utf8.encode(encodedForm));

      var currentRes = await postReq.close();
      collectCookies(currentRes);
      var currentBody = await currentRes.transform(utf8.decoder).join();
      var currentUri = loginUri;

        // 3. Follow redirects (frontdoor.jsp -> ServiceExpert -> lightningLoginFlow) collecting Set-Cookie
      int hops = 0;
      while (hops < 12) {
        String? nextLocation = currentRes.headers.value(
          HttpHeaders.locationHeader,
        );
        if (nextLocation == null || nextLocation.isEmpty) {
          // Salesforce sometimes returns a 200 HTML page with window.location.replace('.../frontdoor.jsp?...')
          // or SfdcApp.projectOneNavigator.handleRedirect('...')
          final jsRedirect = RegExp(
            r'''(?:window\.location(?:\.href|\.replace)?|location\.replace|handleRedirect)\s*(?:=|\()\s*['"]([^'"]+)['"]''',
          ).firstMatch(currentBody);
          if (jsRedirect != null) {
            nextLocation = jsRedirect.group(1);
          }
        }
        if (nextLocation == null || nextLocation.isEmpty) {
          // Check if we landed on loginFlowOnly.apexp with a "Finish Logging In" link to lightningLoginFlow.apexp
          final flowLink = RegExp(
            r'''href=["']([^"']*lightningLoginFlow\.apexp[^"']*)["']''',
            caseSensitive: false,
          ).firstMatch(currentBody);
          if (flowLink != null) {
            nextLocation = flowLink.group(1)!.replaceAll('&amp;', '&');
          }
        }
        if (nextLocation == null || nextLocation.isEmpty) break;

        final nextUri = currentUri.resolve(nextLocation);
        if (nextUri == currentUri) break;
        currentUri = nextUri;

        final redirectReq = await client.getUrl(currentUri);
        redirectReq.followRedirects = false;
        if (cookieJar.isNotEmpty) {
          redirectReq.headers.set(
            HttpHeaders.cookieHeader,
            buildCookieHeader(),
          );
        }
        currentRes = await redirectReq.close();
        collectCookies(currentRes);
        currentBody = await currentRes.transform(utf8.decoder).join();
        hops++;
      }

      // 4. Complete FSL_User_Login_Flow (lightningLoginFlow.apexp) if prompted
      if (currentUri.path.contains('lightningLoginFlow.apexp') ||
          currentBody.contains('FSL_User_Login_Flow')) {
        await _completeSalesforceLightningLoginFlow(
          client: client,
          flowPageUri: currentUri,
          flowHtml: currentBody,
          targetBase: targetBase,
          cookieJar: cookieJar,
          collectCookies: collectCookies,
          buildCookieHeader: buildCookieHeader,
        );
      }

      if (!cookieJar.containsKey('sid')) {
        final errMatch = RegExp(
          r'id="error"[^>]*>([^<]+)<',
          caseSensitive: false,
        ).firstMatch(currentBody);
        final errMsg = errMatch?.group(1)?.trim();
        throw Exception(
          errMsg != null && errMsg.isNotEmpty
              ? 'Salesforce login failed: $errMsg'
              : 'Salesforce login did not return a session cookie. Check your username and password.',
        );
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyFslUsername, cleanUser);
      await prefs.setString(_keyFslPassword, password);
      _fslSavedUsername = cleanUser;
      _fslSavedPassword = password;

      await saveFslSession(
        cookieHeader: buildCookieHeader(),
        baseUrl: targetBase,
      );
    } finally {
      client.close();
    }
  }

  /// Completes Salesforce's mandatory `FSL_User_Login_Flow` (`lightningLoginFlow.apexp`)
  /// using pure HTTP (`A4J.AJAX.Submit`) so the `sid` session cookie is unlocked
  /// for Visualforce Remoting (`FSL__vf001_ServiceExpert`) without needing a browser.
  Future<void> _completeSalesforceLightningLoginFlow({
    required HttpClient client,
    required Uri flowPageUri,
    required String flowHtml,
    required String targetBase,
    required Map<String, String> cookieJar,
    required void Function(HttpClientResponse) collectCookies,
    required String Function() buildCookieHeader,
  }) async {
    String extractHiddenField(String html, String idOrName) {
      final m =
          RegExp(
            '(?:id|name)=["\']${RegExp.escape(idOrName)}["\'][^>]*value=["\']([^"\']*)["\']',
            caseSensitive: false,
          ).firstMatch(html) ??
          RegExp(
            'value=["\']([^"\']*)["\'][^>]*(?:id|name)=["\']${RegExp.escape(idOrName)}["\']',
            caseSensitive: false,
          ).firstMatch(html);
      return m?.group(1) ?? '';
    }

    final vs = extractHiddenField(
      flowHtml,
      'com.salesforce.visualforce.ViewState',
    );
    if (vs.isEmpty) return;

    final vsVer = extractHiddenField(
      flowHtml,
      'com.salesforce.visualforce.ViewStateVersion',
    );
    final vsMac = extractHiddenField(
      flowHtml,
      'com.salesforce.visualforce.ViewStateMAC',
    );
    final vsCsrf = extractHiddenField(
      flowHtml,
      'com.salesforce.visualforce.ViewStateCSRF',
    );

    final ajaxMatch = RegExp(
      r'''A4J\.AJAX\.Submit\(\s*['"]([^'"]+)['"]\s*,\s*null\s*,\s*\{\s*['"]similarityGroupingId['"]\s*:\s*['"]([^'"]+)['"]''',
    ).firstMatch(flowHtml);
    final formId = ajaxMatch?.group(1) ?? 'thePage:j_id8';
    final actionId = ajaxMatch?.group(2) ?? 'thePage:j_id8:j_id9';

    final startPath = Uri.parse(targetBase).path;
    final postFields = <String, String>{
      'AJAXREQUEST': '_viewRoot',
      formId: formId,
      'com.salesforce.visualforce.ViewState': vs,
      if (vsVer.isNotEmpty) 'com.salesforce.visualforce.ViewStateVersion': vsVer,
      if (vsMac.isNotEmpty) 'com.salesforce.visualforce.ViewStateMAC': vsMac,
      if (vsCsrf.isNotEmpty) 'com.salesforce.visualforce.ViewStateCSRF': vsCsrf,
      actionId: actionId,
      'url': '$startPath/apex/FSL__vf001_ServiceExpert',
    };

    final encoded = postFields.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');

    final postUri = Uri.parse('$targetBase/loginflow/lightningLoginFlow.apexp');
    final postReq = await client.postUrl(postUri);
    postReq.followRedirects = false;
    postReq.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/x-www-form-urlencoded; charset=UTF-8',
    );
    postReq.headers.set(HttpHeaders.refererHeader, flowPageUri.toString());
    if (cookieJar.isNotEmpty) {
      postReq.headers.set(HttpHeaders.cookieHeader, buildCookieHeader());
    }
    postReq.add(utf8.encode(encoded));
    final postRes = await postReq.close();
    collectCookies(postRes);
    await postRes.drain<void>();
  }

  /// Unlocks an existing Salesforce session cookie if it is currently gated by
  /// `loginFlowOnly.apexp` / `lightningLoginFlow.apexp`.
  Future<bool> completePendingFslLoginFlowIfNeeded() async {
    if (_fslCookieHeader.trim().isEmpty) return false;
    final cookieJar = <String, String>{};
    for (final part in _fslCookieHeader.split(';')) {
      final idx = part.indexOf('=');
      if (idx > 0) {
        final k = part.substring(0, idx).trim();
        final v = part.substring(idx + 1).trim();
        if (k.isNotEmpty && v.isNotEmpty) {
          cookieJar[k] = v;
        }
      }
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent =
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';

    void collectCookies(HttpClientResponse response) {
      for (final c in response.cookies) {
        if (c.value.isNotEmpty && c.value != 'deleted') {
          cookieJar[c.name] = c.value;
        }
      }
    }

    String buildCookieHeader() =>
        cookieJar.entries.map((e) => '${e.key}=${e.value}').join('; ');

    try {
      final startPath = Uri.parse(_fslBaseUrl).path;
      final retParam = Uri.encodeQueryComponent(
        '$startPath/apex/FSL__vf001_ServiceExpert',
      );
      final flowUri = Uri.parse(
        '$_fslBaseUrl/loginflow/lightningLoginFlow.apexp?retURL=$retParam&sparkID=FSL_User_Login_Flow',
      );
      final req = await client.getUrl(flowUri);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.cookieHeader, buildCookieHeader());
      final res = await req.close();
      collectCookies(res);
      if (res.statusCode != 200) return false;
      final html = await res.transform(utf8.decoder).join();
      if (!html.contains('com.salesforce.visualforce.ViewState')) {
        return false;
      }

      await _completeSalesforceLightningLoginFlow(
        client: client,
        flowPageUri: flowUri,
        flowHtml: html,
        targetBase: _fslBaseUrl,
        cookieJar: cookieJar,
        collectCookies: collectCookies,
        buildCookieHeader: buildCookieHeader,
      );

      await saveFslSession(
        cookieHeader: buildCookieHeader(),
        baseUrl: _fslBaseUrl,
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Signs in to Motive using standard [email] and [password] credentials,
  /// then validates the session to automatically discover the Organization Name
  /// and Company ID.
  Future<MotiveAccountSession> loginMotiveWithCredentials({
    required String email,
    required String password,
    String? customOrgName,
  }) async {
    final cleanEmail = email.trim();
    if (cleanEmail.isEmpty || password.isEmpty) {
      throw Exception('Please enter both Motive email and password.');
    }

    final cookieJar = <String, String>{};
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent =
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';

    void collectCookies(HttpClientResponse response) {
      for (final c in response.cookies) {
        if (c.value.isNotEmpty && c.value != 'deleted') {
          cookieJar[c.name] = c.value;
        }
      }
    }

    String buildCookieHeader() =>
        cookieJar.entries.map((e) => '${e.key}=${e.value}').join('; ');

    String unescapeHtml(String input) {
      return input
          .replaceAll('&amp;', '&')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>');
    }

    try {
      // 1. Follow redirects from https://account.gomotive.com/log-in to https://auth.gomotive.com/login...
      //    while collecting cookies at every hop so CSRF & session cookies match.
      var currentGetUri = Uri.parse('https://account.gomotive.com/log-in');
      var loginHtml = '';
      for (int hop = 0; hop < 8; hop++) {
        final getReq = await client.getUrl(currentGetUri);
        getReq.followRedirects = false;
        if (cookieJar.isNotEmpty) {
          getReq.headers.set(HttpHeaders.cookieHeader, buildCookieHeader());
        }
        final getRes = await getReq.close();
        collectCookies(getRes);
        loginHtml = await getRes.transform(utf8.decoder).join();
        final loc = getRes.headers.value(HttpHeaders.locationHeader);
        if (loc == null || loc.isEmpty) break;
        final nextUri = currentGetUri.resolve(unescapeHtml(loc));
        if (nextUri == currentGetUri) break;
        currentGetUri = nextUri;
      }

      String extractInput(String name) {
        final m =
            RegExp(
              'name=["\']${RegExp.escape(name)}["\'][^>]*value=["\']([^"\']*)["\']',
              caseSensitive: false,
            ).firstMatch(loginHtml) ??
            RegExp(
              'value=["\']([^"\']*)["\'][^>]*name=["\']${RegExp.escape(name)}["\']',
              caseSensitive: false,
            ).firstMatch(loginHtml);
        return unescapeHtml(m?.group(1) ?? '');
      }

      final authTokenCsrf = extractInput('authenticity_token');
      final clientId = extractInput('client_id');
      final returnUrl = extractInput('return_url');

      final actionMatch = RegExp(
        r'''<form[^>]*id=["']sign-in-page-form["'][^>]*action=["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(loginHtml);
      final postUri = actionMatch != null
          ? currentGetUri.resolve(unescapeHtml(actionMatch.group(1)!))
          : currentGetUri.resolve('/login');

      final formFields = <String, String>{
        if (authTokenCsrf.isNotEmpty) 'authenticity_token': authTokenCsrf,
        'user_profile[email]': cleanEmail,
        'user_profile[password]': password,
        'user_profile[remember_me]': '1',
        if (clientId.isNotEmpty) 'client_id': clientId,
        'client_secret': '',
        if (returnUrl.isNotEmpty) 'return_url': returnUrl,
        'ref': 'sign-up',
      };
      final encodedForm = formFields.entries
          .map(
            (e) =>
                '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&');

      final postReq = await client.postUrl(postUri);
      postReq.followRedirects = false;
      postReq.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/x-www-form-urlencoded',
      );
      postReq.headers.set(
        'Origin',
        '${postUri.scheme}://${postUri.host}',
      );
      postReq.headers.set(HttpHeaders.refererHeader, currentGetUri.toString());
      if (cookieJar.isNotEmpty) {
        postReq.headers.set(HttpHeaders.cookieHeader, buildCookieHeader());
      }
      postReq.add(utf8.encode(encodedForm));

      var currentRes = await postReq.close();
      collectCookies(currentRes);
      var currentBody = await currentRes.transform(utf8.decoder).join();
      var currentUri = postUri;

      int hops = 0;
      while (hops < 12) {
        final nextLocation = currentRes.headers.value(
          HttpHeaders.locationHeader,
        );
        if (nextLocation == null || nextLocation.isEmpty) break;
        final nextUri = currentUri.resolve(unescapeHtml(nextLocation));
        if (nextUri == currentUri) break;
        currentUri = nextUri;

        final redirectReq = await client.getUrl(currentUri);
        redirectReq.followRedirects = false;
        if (cookieJar.isNotEmpty) {
          redirectReq.headers.set(
            HttpHeaders.cookieHeader,
            buildCookieHeader(),
          );
        }
        currentRes = await redirectReq.close();
        collectCookies(currentRes);
        currentBody = await currentRes.transform(utf8.decoder).join();
        hops++;
      }

      String? discoveredAuthToken = cookieJar['auth_token'];
      if (discoveredAuthToken == null || discoveredAuthToken.isEmpty) {
        final tokenInBody = RegExp(
          r'"auth_token"\s*:\s*"([^"]+)"',
        ).firstMatch(currentBody);
        discoveredAuthToken = tokenInBody?.group(1);
      }

      if (discoveredAuthToken == null || discoveredAuthToken.isEmpty) {
        throw Exception(
          'Motive login required a browser security check or 2FA. Use "Auto-Detect from Open Browser" or paste your auth_token below.',
        );
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyMotiveEmail, cleanEmail);
      await prefs.setString(_keyMotivePassword, password);
      _motiveSavedEmail = cleanEmail;
      _motiveSavedPassword = password;

      return await validateAndAddMotiveToken(
        rawTokenInput: discoveredAuthToken,
        customOrgName: customOrgName,
      );
    } finally {
      client.close();
    }
  }

  /// Validates a Motive token against `GET https://api.keeptruckin.com/api/w2/sessions/validate`
  /// to automatically discover `organizationId` (`company.id`) and `organizationName`
  /// (`company.name`), then saves the account.
  Future<MotiveAccountSession> validateAndAddMotiveToken({
    required String rawTokenInput,
    String? customOrgName,
    String? customOrgId,
  }) async {
    final cleanToken = extractMotiveToken(rawTokenInput);
    if (cleanToken.isEmpty) {
      throw Exception('Motive token is empty.');
    }

    String discoveredOrgId = customOrgId?.trim() ?? '';
    String discoveredOrgName = customOrgName?.trim() ?? '';

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(
        Uri.parse('https://api.keeptruckin.com/api/w2/sessions/validate'),
      );
      req.headers.set('x-web-user-auth', cleanToken);
      req.headers.set('Accept', 'application/json');
      final res = await req.close();
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          final user = decoded['user'];
          if (user is Map<String, dynamic>) {
            final cc = user['company_connection'];
            if (cc is Map<String, dynamic>) {
              final comp = cc['company'] is Map<String, dynamic>
                  ? cc['company'] as Map<String, dynamic>
                  : null;
              final cid =
                  (cc['company_id'] ?? comp?['id'])?.toString().trim() ?? '';
              if (discoveredOrgId.isEmpty && cid.isNotEmpty) {
                discoveredOrgId = cid;
              }
              if (comp != null) {
                final cname = comp['name']?.toString().trim() ?? '';
                if (discoveredOrgName.isEmpty && cname.isNotEmpty) {
                  discoveredOrgName = cname;
                }
              }
            }
          }
        }
      }
    } catch (_) {
      // Fall back to user-provided or default label if offline
    } finally {
      client.close();
    }

    final session = MotiveAccountSession(
      organizationId: discoveredOrgId,
      organizationName: normalizeMotiveOrgName(
        discoveredOrgName,
        discoveredOrgId,
      ),
      authToken: cleanToken,
    );
    await upsertMotiveAccount(session);
    return session;
  }

  /// Automatically detects and imports active Salesforce FSL and Motive sessions
  /// from an open Chrome/Chromium browser with DevTools Protocol enabled (`127.0.0.1:9222`).
  Future<({bool fslSynced, int motiveAccountsSynced, String message})>
  syncFromOpenBrowserCdp({int port = 9222}) async {
    await _importLocalMotiveAuthFilesIfPresent();

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/json/list'),
      );
      final res = await req.close();
      if (res.statusCode != 200) {
        return (
          fslSynced: false,
          motiveAccountsSynced: 0,
          message: 'No browser detected on port $port.',
        );
      }

      final body = await res.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! List) {
        return (
          fslSynced: false,
          motiveAccountsSynced: 0,
          message: 'Unexpected response from browser on port $port.',
        );
      }

      var fslSynced = false;
      final motiveTokens = <String>{};

      for (final target in decoded) {
        if (target is! Map<String, dynamic>) continue;
        final wsUrl = target['webSocketDebuggerUrl']?.toString();
        final tabUrl = target['url']?.toString() ?? '';
        if (wsUrl == null || wsUrl.isEmpty) continue;
        if (!tabUrl.contains('my.site.com') &&
            !tabUrl.contains('gomotive.com') &&
            !tabUrl.contains('keeptruckin.com') &&
            target['type'] != 'page') {
          continue;
        }

        try {
          final ws = await WebSocket.connect(
            wsUrl,
          ).timeout(const Duration(seconds: 3));
          ws.add(
            jsonEncode(<String, dynamic>{
              'id': 1,
              'method': 'Network.getCookies',
              'params': <String, dynamic>{
                'urls': <String>[
                  'https://aaa-ace.my.site.com',
                  'https://aaa-ace.my.site.com/ACEContractorCommunity',
                  'https://app.gomotive.com',
                  'https://account.gomotive.com',
                  'https://api.keeptruckin.com',
                ],
              },
            }),
          );

          final rawReply = await ws.first.timeout(const Duration(seconds: 3));
          await ws.close();

          final reply = jsonDecode(rawReply.toString());
          final cookies =
              (reply is Map<String, dynamic> &&
                  reply['result'] is Map<String, dynamic> &&
                  (reply['result'] as Map)['cookies'] is List)
              ? (reply['result'] as Map)['cookies'] as List<dynamic>
              : const <dynamic>[];

          final fslPairs = <String>[];
          var hasSid = false;
          String? discoveredFslDomain;

          for (final c in cookies) {
            if (c is! Map<String, dynamic>) continue;
            final name = (c['name'] ?? '').toString().trim();
            final value = (c['value'] ?? '').toString().trim();
            final domain = (c['domain'] ?? '').toString().trim();
            if (name.isEmpty || value.isEmpty) continue;

            if (domain.contains('my.site.com') ||
                domain.contains('force.com')) {
              fslPairs.add('$name=$value');
              if (name == 'sid') hasSid = true;
              final cleanDom = domain.replaceFirst(RegExp(r'^\.+'), '');
              if (discoveredFslDomain == null &&
                  cleanDom.endsWith('.my.site.com') &&
                  cleanDom != 'my.site.com') {
                discoveredFslDomain =
                    'https://$cleanDom/ACEContractorCommunity';
              }
            }

            if (name == 'auth_token' &&
                (domain.contains('gomotive.com') ||
                    domain.contains('keeptruckin.com'))) {
              motiveTokens.add(value);
            }
          }

          if (hasSid && fslPairs.isNotEmpty && !fslSynced) {
            await saveFslSession(
              cookieHeader: fslPairs.join('; '),
              baseUrl: discoveredFslDomain ?? _fslBaseUrl,
            );
            fslSynced = true;
          }
        } catch (_) {
          // Continue checking other tabs
        }
      }

      for (final token in motiveTokens) {
        try {
          await validateAndAddMotiveToken(rawTokenInput: token);
        } catch (_) {}
      }

      final parts = <String>[
        if (fslSynced) 'Salesforce FSL connected',
        if (_motiveAccounts.isNotEmpty)
          '${_motiveAccounts.length} Motive org(s) connected (${_motiveAccounts.map((a) => a.organizationName).join(", ")})',
      ];
      return (
        fslSynced: fslSynced,
        motiveAccountsSynced: _motiveAccounts.length,
        message: parts.isEmpty
            ? 'Browser found on port $port, but no active FSL or Motive login cookies were found yet.'
            : 'Synced: ${parts.join(" • ")}.',
      );
    } catch (_) {
      return (
        fslSynced: false,
        motiveAccountsSynced: _motiveAccounts.length,
        message: 'No debug browser open on port $port.',
      );
    } finally {
      client.close();
    }
  }

  /// Launches Chrome/Chromium pointing to Salesforce FSL and Motive
  /// with `--remote-debugging-port=9222`.
  Future<void> launchBrowserForLogin({int port = 9222}) async {
    final fslUrl = '$_fslBaseUrl/s/dispatch-console';
    const motiveUrl = 'https://app.gomotive.com';

    if (Platform.isLinux) {
      final candidates = <String>[
        'google-chrome',
        'google-chrome-stable',
        'chromium',
        'chromium-browser',
        'brave-browser',
      ];
      for (final bin in candidates) {
        try {
          final whichRes = await Process.run('which', [bin]);
          if (whichRes.exitCode == 0) {
            final profileDir =
                '${Platform.environment['HOME'] ?? '/tmp'}/.config/aaa_tracker_chrome_profile';
            await Process.start(bin, [
              '--remote-debugging-port=$port',
              '--remote-allow-origins=*',
              '--user-data-dir=$profileDir',
              '--profile-directory=Default',
              fslUrl,
              motiveUrl,
            ], mode: ProcessStartMode.detached);
            return;
          }
        } catch (_) {}
      }
      await Process.start('xdg-open', [
        fslUrl,
      ], mode: ProcessStartMode.detached);
    } else if (Platform.isWindows) {
      final localAppData =
          Platform.environment['LOCALAPPDATA'] ?? r'C:\Temp';
      final profileDir = p.join(localAppData, 'AAATrackerChromeProfile');
      final chromePaths = <String>[
        p.join(localAppData, 'Google', 'Chrome', 'Application', 'chrome.exe'),
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
        r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        p.join(
          localAppData,
          'BraveSoftware',
          'Brave-Browser',
          'Application',
          'brave.exe',
        ),
        r'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
      ];
      for (final path in chromePaths) {
        if (File(path).existsSync()) {
          await Process.start(path, [
            '--remote-debugging-port=$port',
            '--remote-allow-origins=*',
            '--user-data-dir=$profileDir',
            fslUrl,
            motiveUrl,
          ], mode: ProcessStartMode.detached);
          return;
        }
      }
      await Process.start('cmd', [
        '/c',
        'start',
        '',
        fslUrl,
      ], mode: ProcessStartMode.detached);
    }
  }

  Future<void> saveFslSession({
    required String cookieHeader,
    String? baseUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final parsed = _parseFslInput(cookieHeader.trim(), baseUrl?.trim());
    _fslCookieHeader = parsed.cookieHeader;
    if (parsed.baseUrl != null && parsed.baseUrl!.isNotEmpty) {
      _fslBaseUrl = parsed.baseUrl!.replaceAll(RegExp(r'/+$'), '');
      await prefs.setString(_keyFslBaseUrl, _fslBaseUrl);
    }
    await prefs.setString(_keyFslCookieHeader, _fslCookieHeader);
  }

  /// Accepts either a raw `Cookie` header string (`sid=...`) OR a Playwright
  /// `auth_state.json` payload (`{"cookies": [...]}`).
  static ({String cookieHeader, String? baseUrl}) _parseFslInput(
    String rawInput,
    String? explicitBaseUrl,
  ) {
    if (rawInput.startsWith('{') && rawInput.contains('"cookies"')) {
      try {
        final decoded = jsonDecode(rawInput);
        if (decoded is Map<String, dynamic> && decoded['cookies'] is List) {
          final cookies = decoded['cookies'] as List<dynamic>;
          final pairs = <String>[];
          String? discoveredHost;
          for (final c in cookies) {
            if (c is Map<String, dynamic>) {
              final name = (c['name'] ?? '').toString().trim();
              final val = (c['value'] ?? '').toString().trim();
              final domain = (c['domain'] ?? '').toString().trim();
              if (name.isNotEmpty && val.isNotEmpty) {
                pairs.add('$name=$val');
              }
              final cleanDom = domain.replaceFirst(RegExp(r'^\.+'), '');
              if (discoveredHost == null &&
                  cleanDom.endsWith('.my.site.com') &&
                  cleanDom != 'my.site.com') {
                discoveredHost = 'https://$cleanDom/ACEContractorCommunity';
              }
            }
          }
          if (pairs.isNotEmpty) {
            return (
              cookieHeader: pairs.join('; '),
              baseUrl: (explicitBaseUrl != null && explicitBaseUrl.isNotEmpty)
                  ? explicitBaseUrl
                  : discoveredHost,
            );
          }
        }
      } catch (_) {
        // Fall through to raw string
      }
    }
    return (cookieHeader: rawInput, baseUrl: explicitBaseUrl);
  }

  /// Accepts either a raw `x-web-user-auth` token string, a `motive_auth.json`
  /// object (`{"token": "..."}`), OR a Playwright `auth_state.json` payload.
  static String extractMotiveToken(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          if (decoded['token'] is String &&
              (decoded['token'] as String).trim().isNotEmpty) {
            return (decoded['token'] as String).trim();
          }
          if (decoded['cookies'] is List) {
            for (final c in decoded['cookies'] as List<dynamic>) {
              if (c is Map<String, dynamic> && c['name'] == 'auth_token') {
                final v = (c['value'] ?? '').toString().trim();
                if (v.isNotEmpty) return v;
              }
            }
          }
        }
      } catch (_) {}
    }
    return trimmed;
  }

  Future<void> saveMotiveAccounts(List<MotiveAccountSession> accounts) async {
    final prefs = await SharedPreferences.getInstance();
    _motiveAccounts = List.unmodifiable(accounts);
    final encoded = jsonEncode(_motiveAccounts.map((a) => a.toJson()).toList());
    await prefs.setString(_keyMotiveAccounts, encoded);
  }

  Future<void> upsertMotiveAccount(MotiveAccountSession session) async {
    final cleanToken = extractMotiveToken(session.authToken);
    final cleanOrgId = session.organizationId.trim();
    final normalizedSession = MotiveAccountSession(
      organizationId: cleanOrgId,
      organizationName: normalizeMotiveOrgName(
        session.organizationName,
        cleanOrgId,
      ),
      authToken: cleanToken,
    );

    final updated = <MotiveAccountSession>[];
    bool replaced = false;
    for (final existing in _motiveAccounts) {
      final sameOrg =
          normalizedSession.organizationId.isNotEmpty &&
          existing.organizationId == normalizedSession.organizationId;
      final sameName =
          normalizedSession.organizationId.isEmpty &&
          existing.organizationName.toLowerCase() ==
              normalizedSession.organizationName.toLowerCase();
      final sameToken = existing.authToken == normalizedSession.authToken;
      if (sameOrg || sameName || sameToken) {
        updated.add(normalizedSession);
        replaced = true;
      } else {
        updated.add(existing);
      }
    }
    if (!replaced) {
      updated.add(normalizedSession);
    }
    await saveMotiveAccounts(updated);
  }

  Future<void> removeMotiveAccount(MotiveAccountSession target) async {
    final updated = _motiveAccounts
        .where(
          (a) =>
              !(a.organizationId == target.organizationId &&
                  a.organizationName == target.organizationName &&
                  a.authToken == target.authToken),
        )
        .toList();
    await saveMotiveAccounts(updated);
  }
}
