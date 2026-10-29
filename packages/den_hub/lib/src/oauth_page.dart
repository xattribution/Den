import 'dart:convert';
import 'dart:io';

const HtmlEscape _html = HtmlEscape();

/// The Content-Security-Policy for the hub's own sign-in pages: nothing but the page's own
/// inline style and script (by [nonce]), fonts from the hub, and polling the hub.
String oauthPagePolicy(String nonce) => [
      "default-src 'none'",
      "script-src 'nonce-$nonce'",
      "style-src 'nonce-$nonce'",
      "font-src 'self'",
      "connect-src 'self'",
      "img-src 'self'",
      "base-uri 'none'",
      "form-action 'none'",
      "frame-ancestors 'none'",
    ].join('; ');

/// The page a person sees while an OAuth client waits for a parent's approval, in Den's design
/// tokens (the page gray and ink, true black at night, Atkinson Hyperlegible Next when the web
/// app ships it). It names the app by what it calls itself and, so a made-up name can't pass for
/// another app, by [host],
/// where its sign-in returns to; and shows [code], which the parent's app shows beside the same
/// request. With [loopback] (it returns to this computer, where any program could be
/// listening) it says so; [describedAt] is the host of a client's metadata document. With
/// [failed] it explains that the sign-in link doesn't work instead. [nonce] is the CSP nonce of
/// its inline style and script ([oauthPagePolicy]).
String authorizePage({
  required String client,
  required List<String> scopes,
  required String? requestId,
  required String status,
  required String nonce,
  String host = '',
  String code = '',
  String? webDir,
  bool failed = false,
  bool loopback = false,
  String? describedAt,
}) {
  final fontFile = webDir == null
      ? null
      : File('$webDir${Platform.pathSeparator}assets${Platform.pathSeparator}assets${Platform.pathSeparator}fonts'
          '${Platform.pathSeparator}AtkinsonHyperlegibleNext.ttf');
  final font = fontFile != null && fontFile.existsSync()
      ? "@font-face{font-family:'Atkinson Hyperlegible Next';src:url('/assets/assets/fonts/AtkinsonHyperlegibleNext.ttf');}"
      : '';
  final name = _html.convert(client);
  final title = failed ? 'Den sign-in' : 'Approve $name in Den';
  final intro = failed
      ? '<h1>This sign-in link doesn\'t work</h1>'
      : '<h1>Approve $name in the Den app</h1>\n'
          '${host.isEmpty ? '' : loopback ? '<p class="from">It signs in for <strong>a program on this computer</strong> (${_html.convert(host)}). Any program here could ask, so only approve it if you just started it.</p>\n' : '<p class="from">It signs in for <strong>${_html.convert(host)}</strong>. Only approve it if that is where you started.</p>\n'}'
          '${describedAt == null ? '' : '<p class="meta">It describes itself at ${_html.convert(describedAt)}.</p>\n'}'
          '<p>A parent needs to say yes on their phone before $name can use your family\'s Den.</p>\n'
          '<p class="where">Settings &rarr; Advanced &rarr; AI and automations</p>\n'
          '${code.isEmpty ? '' : '<p>Den shows this request with the code <strong class="code">${_html.convert(code)}</strong>. Approve the one with the same code.</p>\n'}'
          '${scopes.isEmpty ? '' : '<p class="meta">It asked to: ${_html.convert(_scopeWords(scopes))}.</p>'}';
  final poll = requestId == null ? '' : _pollScript(requestId, nonce);
  return '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style nonce="$nonce">
$font
:root{--paper:#F2F2F2;--well:#FFFFFF;--rule:#E0E0E0;--ink:#141414;--ink2:#595959;color-scheme:light dark;}
@media (prefers-color-scheme: dark){:root{--paper:#000000;--well:#141414;--rule:#262626;--ink:#F2F2F2;--ink2:#A6A6A6;}}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font-family:'Atkinson Hyperlegible Next',system-ui,-apple-system,'Segoe UI',sans-serif;font-size:17px;line-height:1.35;}
main{max-width:480px;margin:0 auto;padding:48px 16px;}
h1{font-size:26px;font-weight:800;line-height:1.2;margin:0 0 16px;}
p{margin:0 0 12px;}
.meta{font-size:15px;color:var(--ink2);}
.from{background:var(--well);border-radius:20px;padding:12px 16px;}
.code{font-size:18px;letter-spacing:1px;}
.where{background:var(--well);border-radius:20px;padding:12px 16px;margin:24px 0;font-weight:700;}
#status{border-top:1px solid var(--rule);padding-top:16px;margin-top:24px;color:var(--ink2);}
</style>
</head>
<body>
<main>
$intro
<p id="status" role="status" aria-live="polite">${_html.convert(status)}</p>
</main>
$poll
</body>
</html>''';
}

String _pollScript(String requestId, String nonce) => '''
<script nonce="$nonce">
(function () {
  var id = ${jsonEncode(requestId)};
  var line = document.getElementById('status');
  function tick() {
    fetch('/oauth/authorize/status?request=' + encodeURIComponent(id), {cache: 'no-store'})
      .then(function (r) { return r.json(); })
      .then(function (s) {
        if (s.message) line.textContent = s.message;
        if (s.redirect) { window.location.replace(s.redirect); return; }
        if (s.state === 'pending') setTimeout(tick, 2000);
      })
      .catch(function () { setTimeout(tick, 4000); });
  }
  setTimeout(tick, 1500);
})();
</script>
<noscript><meta http-equiv="refresh" content="5;url=/oauth/authorize?request=${Uri.encodeQueryComponent(requestId)}"></noscript>''';

String _scopeWords(List<String> scopes) {
  const words = {
    'read': 'see the calendar, chores, lists and points',
    'calendar': 'change events',
    'chores': 'check off chores',
    'lists': 'change lists',
    'points': 'give stars and handle rewards',
    'admin': 'do everything a parent can, except family settings',
  };
  final parts = [for (final s in scopes) words[s] ?? s];
  if (parts.length <= 1) return parts.join();
  return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
}

/// A plain page for an OAuth request that can't go on (bad client, bad redirect address).
String oauthErrorPage(String message, {required String nonce, String? webDir}) =>
    authorizePage(client: '', scopes: const [], requestId: null, status: message, nonce: nonce, webDir: webDir, failed: true);
