import 'dart:convert';
import 'dart:io';

const HtmlEscape _html = HtmlEscape();

/// The page a person sees while an OAuth client waits for a parent's approval, in Den's design
/// tokens (paper and ink, Atkinson Hyperlegible Next when the web app ships it). With [failed]
/// it explains that the sign-in link doesn't work instead.
String authorizePage({
  required String client,
  required List<String> scopes,
  required String? requestId,
  required String status,
  String? webDir,
  bool failed = false,
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
          '<p>A parent needs to say yes on their phone before $name can use your family\'s Den.</p>\n'
          '<p class="where">Settings &rarr; AI and automations</p>'
          '${scopes.isEmpty ? '' : '\n<p class="meta">It asked to: ${_html.convert(_scopeWords(scopes))}.</p>'}';
  final poll = requestId == null ? '' : _pollScript(requestId);
  return '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
$font
:root{--paper:#FBFAF7;--well:#F2F0EC;--rule:#DCD9D3;--ink:#231E19;--ink2:#5F5A54;color-scheme:light dark;}
@media (prefers-color-scheme: dark){:root{--paper:#15120F;--well:#211D1A;--rule:#393530;--ink:#F0EEEA;--ink2:#AFAAA4;}}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font-family:'Atkinson Hyperlegible Next',system-ui,-apple-system,'Segoe UI',sans-serif;font-size:15px;line-height:1.5;}
main{max-width:480px;margin:0 auto;padding:48px 16px;}
h1{font-size:24px;font-weight:700;margin:0 0 16px;}
p{margin:0 0 12px;}
.meta{font-size:13px;color:var(--ink2);}
.where{background:var(--well);border-radius:6px;padding:12px 16px;margin:24px 0;font-weight:700;}
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

String _pollScript(String requestId) => '''
<script>
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
String oauthErrorPage(String message, {String? webDir}) =>
    authorizePage(client: '', scopes: const [], requestId: null, status: message, webDir: webDir, failed: true);
