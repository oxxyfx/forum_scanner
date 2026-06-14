import 'dart:convert' show jsonEncode;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'forum_source.dart';
import 'smf_service.dart';

/// Full in-app browser view of a forum — opened via long-press on the
/// "Posts" tab. Shows the real forum site (all categories, navigation,
/// etc.) exactly as it would appear in a normal browser, pre-authenticated
/// using the same login the rest of the app uses for syncing.
class ForumWebViewScreen extends StatefulWidget {
  final ForumSource source;

  const ForumWebViewScreen({super.key, required this.source});

  @override
  State<ForumWebViewScreen> createState() => _ForumWebViewScreenState();
}

class _ForumWebViewScreenState extends State<ForumWebViewScreen> {
  late final WebViewController _controller;
  double _progress = 0;
  bool _loading = true;
  String? _error;

  // True once we've tried driving the real login form in the WebView, so
  // we don't loop forever if the credentials are wrong or the page never
  // leaves /login.
  bool _formLoginAttempted = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress / 100);
          },
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _error = null;
            });
          },
          onPageFinished: (url) {
            if (!mounted) return;
            setState(() => _loading = false);

            // The cookie hand-off below doesn't always take (e.g. NodeBB
            // session cookies that didn't carry over cleanly between the
            // Dio client and the WebView's cookie store). If we land on the
            // login page, drive the real login form once, the way a person
            // would in a browser.
            if (!_formLoginAttempted && url.contains('/login')) {
              _formLoginAttempted = true;
              _attemptFormLogin();
            }
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            // Ignore errors for sub-resources (images, ads, etc.) — only
            // surface failures for the main frame.
            if (error.isForMainFrame == false) return;
            setState(() {
              _loading = false;
              _error = error.description;
            });
          },
        ),
      );
    _init();
  }

  Future<void> _init() async {
    final baseUrl = widget.source.baseUrl.trim();

    // Log in the same way the rest of the app does, then copy the resulting
    // session cookies into the WebView so it opens already signed in.
    try {
      final service = SmfService(source: widget.source);
      final loggedIn = await service.login();
      if (loggedIn) {
        await _copyCookiesToWebView(service, baseUrl);
      }
    } catch (_) {
      // Fall back to loading the page logged out — the user can sign in
      // manually inside the WebView.
    }

    if (!mounted) return;
    // Always start at /login rather than the forum root: NodeBB redirects
    // /login straight to the home page if the session cookie we just copied
    // in is valid (so authenticated users never actually see this page —
    // the redirect happens before anything renders). If the cookie hand-off
    // didn't take, we land on the real login page and onPageFinished below
    // drives the form with the stored credentials.
    await _controller.loadRequest(Uri.parse('$baseUrl/login'));
  }

  Future<void> _copyCookiesToWebView(SmfService service, String baseUrl) async {
    final cookies = await service.cookiesForWebView();
    if (cookies.isEmpty) return;

    final host = Uri.parse(baseUrl).host;
    final cookieManager = WebViewCookieManager();
    for (final cookie in cookies) {
      final domain = (cookie.domain ?? host).replaceFirst(RegExp(r'^\.'), '');
      if (domain.isEmpty) continue;
      final path = cookie.path;
      await cookieManager.setCookie(
        WebViewCookie(
          name: cookie.name,
          value: cookie.value,
          domain: domain,
          path: (path != null && path.isNotEmpty) ? path : '/',
        ),
      );
    }
  }

  /// Fills in and submits the forum's normal login form via JavaScript,
  /// using the stored credentials — exactly as if the user had typed them
  /// in a browser. Used as a fallback when the cookie hand-off in [_init]
  /// doesn't result in an authenticated session.
  Future<void> _attemptFormLogin() async {
    final username = widget.source.username.trim();
    final password = widget.source.password;
    if (username.isEmpty || password.isEmpty) return;

    final usernameJs = jsonEncode(username);
    final passwordJs = jsonEncode(password);

    try {
      await _controller.runJavaScript('''
        (function() {
          var u = document.querySelector('#login-username, input[name="username"], input[type="email"]');
          var p = document.querySelector('#login-password, input[name="password"], input[type="password"]');
          if (!u || !p) return;
          u.value = $usernameJs;
          p.value = $passwordJs;
          ['input', 'change'].forEach(function(evt) {
            u.dispatchEvent(new Event(evt, { bubbles: true }));
            p.dispatchEvent(new Event(evt, { bubbles: true }));
          });
          var form = u.form || p.form || document.querySelector('form');
          var btn = (form || document).querySelector('button[type="submit"], input[type="submit"], #login, #login-form button');
          if (btn) {
            btn.click();
          } else if (form) {
            form.submit();
          }
        })();
      ''');
    } catch (_) {
      // Best-effort only — if this fails the user can still log in manually.
    }
  }

  Future<void> _openInBrowser() async {
    final current = await _controller.currentUrl();
    final url = (current != null && current.isNotEmpty) ? current : widget.source.baseUrl.trim();
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        } else if (mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          // Tapping this immediately leaves the WebView and returns to the
          // app — regardless of the page's own navigation history (unlike
          // the system back button, which steps through it first).
          title: TextButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).appBarTheme.foregroundColor ?? Theme.of(context).colorScheme.onSurface,
            ),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back to App'),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.home),
              tooltip: 'Forum home',
              onPressed: () => _controller.loadRequest(Uri.parse(widget.source.baseUrl.trim())),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload',
              onPressed: () => _controller.reload(),
            ),
            IconButton(
              icon: const Icon(Icons.open_in_browser),
              tooltip: 'Open in browser',
              onPressed: _openInBrowser,
            ),
          ],
        ),
        body: Column(
          children: [
            if (_loading)
              LinearProgressIndicator(value: _progress > 0 && _progress < 1 ? _progress : null),
            if (_error != null)
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.errorContainer,
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Failed to load page: $_error',
                  style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                ),
              ),
            Expanded(child: WebViewWidget(controller: _controller)),
          ],
        ),
      ),
    );
  }
}
