/// Accounts: signing in to the hub with Google or Apple (oidc.dart), the browser sessions that
/// follow, and binding a parent's account to their member (ARCHITECTURE.md "Accounts",
/// docs/hub-api.md "Signing in with Google and Apple").
///
/// Phase 1 of docs/auth/ACCOUNT_FIRST_REVIEW.md: an account signs in as the member it is bound
/// to, and nothing else changes about devices. A sign-in whose account is bound to nobody here
/// gets one generic answer and creates nothing.
library;

import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:cryptography/dart.dart';
import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show DeviceRequestCheck;
import 'package:shelf/shelf.dart';

import 'context.dart';
import 'device_auth.dart';
import 'edge.dart';
import 'http_util.dart';
import 'oidc.dart';

/// One sign-in on its way through the provider, kept by the hub under its `state` (hashed)
/// until it comes back, once.
class _Flow {
  _Flow({
    required this.provider,
    required this.nonce,
    required this.verifier,
    required this.browser,
    required this.created,
    required this.client,
    this.binding,
  });

  final String provider;
  final String nonce;

  /// The client it came from ([HubContext.clientOf]): each keeps only a few plain sign-ins.
  final String client;

  /// The PKCE verifier, which never leaves the hub but for the token endpoint.
  final String verifier;

  /// SHA-256 of the flow cookie the browser that started it holds: only that browser finishes.
  final String browser;
  final int created;

  /// The binding a parent's phone started this for, or null for a plain sign-in.
  final _Binding? binding;

  /// What Apple's form post brought (form_post), until the browser comes back with its cookie.
  bool posted = false;
  String? code;
  String? error;

  bool expired(int now) => now - created > HubAccounts.flowLifetime.inMilliseconds;
}

/// A browser signed in as a member, kept by the hub under its cookie's hash.
class _Session {
  _Session({required this.member, required this.account, required this.created});

  final String member;

  /// The account it signed in with: the session ends when the member no longer has it.
  final AccountRef account;
  final int created;

  int get expires => created + HubAccounts.sessionLifetime.inMilliseconds;
}

/// What a sign-in to bind an account found.
class _Bound {
  _Bound(this.account, this.email);
  final AccountRef account;
  final String email;
}

/// A parent's phone binding their account: started by a request it signed, finished by a
/// sign-in in a browser that opened [ticket]'s start link, read back once by the same phone.
class _Binding {
  _Binding({
    required this.id,
    required this.ticket,
    required this.device,
    required this.member,
    required this.provider,
    required this.created,
  });

  /// SHA-256 of the id the phone reads it back by.
  final String id;

  /// SHA-256 of the ticket in the start link.
  final String ticket;
  final String device;
  final String member;
  final String provider;
  final int created;

  /// Whether a browser has opened the start link: a second one spoils it.
  bool started = false;
  _Bound? result;
  String? failure;

  bool expired(int now) => now - created > HubAccounts.bindingLifetime.inMilliseconds;

  void fail(String message) {
    failure ??= message;
    result = null;
  }
}

/// Signing in with Google and Apple: the `/auth` routes, browser sessions, `/api/v1/me`, and the
/// bindings a parent's own phone asks for. With no provider configured (or no https public URL
/// for them to send people back to), none of these routes exist.
///
/// Sessions live only in the hub's memory, under the SHA-256 of a random cookie (`__Host-`,
/// `Secure`, `HttpOnly`, `SameSite=Lax`, [sessionLifetime]); a restart signs everyone out. Each
/// sign-in makes a new one and ends whatever session the browser had. A session ends the moment
/// its member no longer has the account it signed in with (unbound, rebound or removed).
///
/// Binding never writes the family's log: the hub can't, by validity.dart's rule for
/// `member.account`. A parent's own phone asks for a binding (a signed request), opens its start
/// link in a browser, signs in there, and reads the result back with another signed request,
/// once; the phone then writes `member.account` itself. A session cookie plays no part in it, a
/// start link opened twice spoils it, and a sign-in comes back once, to the browser that began it.
class HubAccounts {
  /// Accounts for [hub]; [auth] checks the parent's phone's signed requests.
  HubAccounts(this.hub, this.auth);

  /// Shared hub context.
  final HubContext hub;

  /// Checks requests signed by the family's devices.
  final DeviceAuth auth;

  /// The session cookie.
  static const String sessionCookie = '__Host-den_session';

  /// The cookie that ties a sign-in to the browser that began it.
  static const String flowCookie = '__Host-den_signin';

  /// How long a browser stays signed in.
  static const Duration sessionLifetime = Duration(hours: 12);

  /// How long a sign-in may take at the provider.
  static const Duration flowLifetime = Duration(minutes: 10);

  /// How long a parent's phone has to finish binding.
  static const Duration bindingLifetime = Duration(minutes: 10);

  /// Most sign-ins on their way at once, by default. Past it, the oldest plain sign-in makes
  /// room; a sign-in finishing a binding never does, and nobody is turned away (review finding
  /// F2: a few addresses could otherwise fill the store and keep everyone out).
  static const int defaultMaxFlows = 5000;

  /// [defaultMaxFlows]; tests lower it.
  int maxFlows = defaultMaxFlows;

  /// Most plain sign-ins one client has on their way: a new one ends its oldest.
  static const int maxFlowsPerClient = 4;

  /// Most browsers signed in at once; past it, the oldest session ends.
  static const int maxSessions = 2000;

  /// Most bindings waiting at once, and per phone.
  static const int maxBindings = 100;

  /// See [maxBindings].
  static const int maxBindingsPerDevice = 3;

  final Map<String, _Flow> _flows = {};
  final Map<String, _Session> _sessions = {};
  final Map<String, _Binding> _bindings = {};
  final Map<String, _Binding> _tickets = {};
  bool _enabled = false;

  /// The providers configured for this hub.
  SignInProviders? get providers => hub.config.signIn;

  /// Whether the routes are there: a provider is configured and the hub has an https public URL.
  bool get enabled => _enabled;

  /// Browsers signed in now (tests).
  int get sessionCount => _sessions.length;

  /// Sign-ins on their way now (tests).
  int get flowCount => _flows.length;

  /// Adds the routes, when a provider is configured. Without one the hub answers none of them,
  /// as before.
  void register(Routes routes) {
    final configured = providers?.all ?? const <OidcProvider>[];
    if (configured.isEmpty) return;
    final public = hub.config.publicUrl;
    if (public == null || !public.isScheme('https') || public.host.isEmpty) {
      hub.log.warn('Sign-in with ${configured.map((p) => p.name).join(' and ')} is off: it needs DEN_PUBLIC_URL to be '
          'the hub\'s https address, where ${configured.length == 1 ? 'it sends' : 'they send'} people back to.');
      return;
    }
    _enabled = true;
    for (final p in configured) {
      routes
        ..add('GET', '/auth/oidc/${p.id}/start', (r, _) => _limited(r, () => start(r, p)))
        ..add('POST', '/auth/oidc/${p.id}/start', (r, _) => _limited(r, () => startBinding(r, p)))
        ..add('GET', '/auth/oidc/${p.id}/callback', (r, _) => _limited(r, () => callback(r, p)));
      if (p.formPost) routes.add('POST', '/auth/oidc/${p.id}/callback', (r, _) => _limited(r, () => formPost(r, p)));
    }
    routes
      ..add('POST', '/auth/logout', (r, _) => _limited(r, () => logout(r)))
      ..add('GET', '/api/v1/me', (r, _) => me(r))
      ..add('GET', '/api/v1/account/providers', (r, _) => listProviders(r))
      ..add('POST', '/api/v1/account/bindings', (r, _) => createBinding(r))
      ..add('GET', '/api/v1/account/bindings/<id>', (r, p) => pollBinding(r, p['id']!));
    hub.log.info('Signing in with ${configured.map((p) => p.name).join(' and ')} at ${urlOf(public, '/auth')}');
  }

  /// Where [p] sends people back: the hub's public URL, `/auth/oidc/<p>/callback`.
  String redirectUri(OidcProvider p) => urlOf(hub.config.publicUrl!, '/auth/oidc/${p.id}/callback');

  // ------------------------------------------------------------------ the browser's side

  /// [body], within the `/auth` budget per client ([Limits.auth]).
  Future<Response> _limited(Request r, Future<Response> Function() body) async {
    final key = hub.clientOf(r);
    if (!hub.limits.allow('auth', key, Limits.auth)) {
      final wait = hub.limits.retryAfter('auth', key, Limits.auth);
      return _page(429, 'Too many tries', 'Too many sign-ins from here. Wait a few minutes, then try again.',
          headers: {'retry-after': '$wait'});
    }
    return body();
  }

  /// `GET /auth/oidc/<provider>/start`: sends the browser to the provider, with `state`, a
  /// `nonce` and PKCE, and a cookie only this browser holds.
  ///
  /// With `?bind=<ticket>` (the link a parent's phone opens) it only asks: a page that says whose
  /// account this makes it and a button that posts back here ([startBinding]). Opening the link
  /// changes nothing, so a link preview or a scanner that fetches it spoils nothing (finding F6).
  Future<Response> start(Request r, OidcProvider p) async {
    final now = hub.now();
    _prune(now);
    final ticket = r.url.queryParameters['bind'];
    if (ticket != null) return _confirm(p, ticket, now);
    return _begin(r, p, null, now);
  }

  /// The page that asks before a binding's sign-in starts: no script, a strict policy, every
  /// name escaped, one same-origin form.
  Response _confirm(OidcProvider p, String ticket, int now) {
    final binding = _tickets[_sha(ticket)];
    final member = binding == null ? null : hub.den.member(binding.member);
    if (binding == null || member == null || binding.expired(now) || binding.provider != p.id || binding.failure != null || binding.started) {
      return _expired();
    }
    final family = hub.den.family?.name;
    final where = family == null ? 'your family\'s Den' : '$family\'s Den';
    return _page(
      200,
      'Sign in as ${member.name}?',
      'This makes the ${p.name} account you choose sign in as ${member.name} in $where. Continue only if you are '
          '${member.name}. If you didn\'t just start this in Den on your phone, close this page.',
      form: (action: '/auth/oidc/${p.id}/start', fields: {'bind': ticket}, label: 'Continue to ${p.name}'),
    );
  }

  /// `POST /auth/oidc/<provider>/start` `bind=<ticket>`, from the page [_confirm] shows (its
  /// `Origin` must be the hub's): starts the sign-in that finishes the binding. A ticket starts
  /// one sign-in; a second one spoils the binding, so neither binds anything.
  Future<Response> startBinding(Request r, OidcProvider p) async {
    final origin = r.headers['origin'];
    if (origin == null || origin != hub.config.publicUrl!.origin) {
      hub.failed(r);
      return _page(403, 'Start from Den', 'This sign-in starts from the page Den opened for it. Start again in Den.',
          headers: _clearFlow);
    }
    if (r.mimeType != 'application/x-www-form-urlencoded') return _expired();
    final Map<String, String> form;
    try {
      form = Uri.splitQueryString(utf8.decode(await readBodyBytes(r, limit: 4096)));
    } on Object {
      return _expired();
    }
    final ticket = form['bind'];
    final now = hub.now();
    _prune(now);
    final binding = ticket == null ? null : _tickets[_sha(ticket)];
    if (binding == null || binding.expired(now) || binding.provider != p.id || binding.failure != null) return _expired();
    return _begin(r, p, binding, now);
  }

  /// Starts a sign-in through [p], for [binding] or (null) a plain one. The provider's endpoints
  /// come first; then, with nothing awaited in between, the binding is checked and marked
  /// started, so two posts of one ticket can't both start (finding F1).
  Future<Response> _begin(Request r, OidcProvider p, _Binding? binding, int now) async {
    final OidcEndpoints endpoints;
    try {
      endpoints = await p.endpoints(hub.fetch, now);
    } on OidcRefused catch (e) {
      hub.log.warn('Can\'t start a sign-in with ${p.name}: ${e.reason}');
      return _unavailable(p);
    }
    if (binding != null) {
      if (binding.failure != null || binding.expired(hub.now())) return _expired();
      if (binding.started) {
        // A second sign-in for one binding: whoever that is, neither binds anything now.
        binding.fail('The sign-in link was used twice, so it doesn\'t bind anything. Start again in Den.');
        hub.log.warn('A link to bind an account was used a second time; it binds nothing now');
        return _expired();
      }
      binding.started = true;
    }
    final state = randomToken(), nonce = randomToken(), verifier = randomToken(), browser = randomToken();
    _keep(
      _sha(state),
      _Flow(provider: p.id, nonce: nonce, verifier: verifier, browser: _sha(browser), created: now, client: hub.clientOf(r), binding: binding),
    );
    final to = p.authorizeUrl(endpoints, redirectUri: redirectUri(p), state: state, nonce: nonce, challenge: pkceChallenge(verifier));
    return Response.found(to, headers: {'set-cookie': _cookie(flowCookie, browser, flowLifetime), 'cache-control': 'no-store'});
  }

  /// Keeps [flow] under [key]. A client keeps at most [maxFlowsPerClient] plain sign-ins, its
  /// oldest ending first; past [maxFlows] the oldest plain sign-in of anyone's ends. A sign-in
  /// finishing a binding is never ended this way (there are at most [maxBindings] of those), and
  /// nobody is turned away.
  void _keep(String key, _Flow flow) {
    if (flow.binding == null) {
      final mine = [for (final e in _flows.entries) if (e.value.binding == null && e.value.client == flow.client) e.key];
      while (mine.length >= maxFlowsPerClient) {
        _flows.remove(mine.removeAt(0));
      }
      while (_flows.length >= maxFlows) {
        final oldest = _flows.entries.where((e) => e.value.binding == null).firstOrNull;
        if (oldest == null) break;
        _flows.remove(oldest.key);
      }
    }
    _flows[key] = flow;
  }

  /// `POST /auth/oidc/apple/callback`: Apple posts the code here (form_post). The browser's
  /// cookie doesn't come along on a post from another site (`SameSite=Lax`), so the hub keeps the
  /// code with its sign-in and sends the browser back here with a plain GET, which brings it.
  Future<Response> formPost(Request r, OidcProvider p) async {
    final origin = r.headers['origin'];
    if (origin != null && origin != Uri.parse(p.issuer).origin) {
      hub.failed(r);
      return _expired();
    }
    if (r.mimeType != 'application/x-www-form-urlencoded') return _expired();
    final Map<String, String> form;
    try {
      form = Uri.splitQueryString(utf8.decode(await readBodyBytes(r, limit: 16 * 1024)));
    } on Object {
      return _expired();
    }
    final state = form['state'];
    final flow = state == null ? null : _flows[_sha(state)];
    if (flow == null || flow.provider != p.id || flow.expired(hub.now())) return _expired();
    if (flow.posted) {
      // A second post for one sign-in: a replay, or someone else's code. It finishes nothing.
      _flows.remove(_sha(state!));
      flow.binding?.fail('That sign-in came back twice, so it doesn\'t bind anything. Start again in Den.');
      return _expired();
    }
    flow
      ..posted = true
      ..code = form['code']
      ..error = form['error'];
    return Response(303, headers: {
      'location': '${redirectUri(p)}?state=${Uri.encodeQueryComponent(state!)}',
      'cache-control': 'no-store',
    });
  }

  /// `GET /auth/oidc/<provider>/callback`: the provider sends the browser back. The sign-in it
  /// names is used up at once, whatever happens next; it must come back to the browser that
  /// began it; and the hub exchanges the code and checks the ID token itself (oidc.dart). Then it
  /// signs the browser in as the member the account is bound to, or (to bind) hands the result
  /// to the parent's phone. An account bound to nobody here gets [noAccountPage], and nothing is
  /// made.
  Future<Response> callback(Request r, OidcProvider p) async {
    final now = hub.now();
    final q = r.url.queryParameters;
    final state = q['state'];
    final flow = state == null ? null : _flows.remove(_sha(state));
    if (flow == null || flow.provider != p.id || flow.expired(now)) return _expired();
    final binding = flow.binding;
    final browser = cookie(r, flowCookie);
    if (browser == null || !textEqual(_sha(browser), flow.browser)) {
      binding?.fail('The sign-in finished in another browser, so it doesn\'t bind anything. Start again in Den.');
      hub.log.warn('A sign-in with ${p.name} came back to a browser that didn\'t start it');
      return _expired();
    }
    final iss = q['iss'];
    if (iss != null && !p.issuers.contains(iss)) {
      binding?.fail('Den couldn\'t sign you in. Start again in Den.');
      return _failed();
    }
    final error = p.formPost ? flow.error : q['error'];
    final code = p.formPost ? flow.code : q['code'];
    if (error != null) {
      binding?.fail('The sign-in was cancelled.');
      return _page(400, 'Sign-in cancelled', 'Nothing changed. Start again whenever you\'re ready.', headers: _clearFlow);
    }
    if (code == null || code.isEmpty || code.length > 4096) {
      binding?.fail('Den couldn\'t sign you in. Start again in Den.');
      return _failed();
    }
    final OidcIdentity who;
    try {
      final token = await p.exchange(hub.fetch, code: code, verifier: flow.verifier, redirectUri: redirectUri(p), now: now);
      who = await p.verify(hub.fetch, token, nonce: flow.nonce, now: hub.now());
    } on OidcRefused catch (e) {
      hub.log.warn('Refused a sign-in with ${p.name}: ${e.reason}');
      final page = switch (e.kind) {
        OidcRefusal.relayEmail => _page(403, 'Den needs your real email',
            'Den doesn\'t take Hide My Email addresses. In your Apple Account settings, stop using Sign in with Apple for '
                'Den, then sign in again and choose Share My Email.',
            headers: _clearFlow),
        OidcRefusal.unverifiedEmail =>
          _page(403, 'Den needs a verified email', 'Verify the email of that account first, or sign in with another.', headers: _clearFlow),
        OidcRefusal.unavailable => _unavailable(p),
        OidcRefusal.invalid => _failed(),
      };
      binding?.fail(switch (e.kind) {
        OidcRefusal.relayEmail => 'Den doesn\'t take Hide My Email addresses. Choose Share My Email.',
        OidcRefusal.unverifiedEmail => 'That account\'s email isn\'t verified.',
        OidcRefusal.unavailable => '${p.name} sign-in isn\'t working right now. Try again in a few minutes.',
        OidcRefusal.invalid => 'Den couldn\'t sign you in. Start again in Den.',
      });
      return page;
    }
    if (binding != null) return await _bind(binding, who, p);
    return _signIn(r, who, p);
  }

  /// The member [who] is bound to here: none before the hub is in a family, none when no one
  /// (or more than one) has that account, and, in this phase, none who isn't a parent now. A
  /// parent made something else keeps a dormant binding that signs in as nobody (finding F4);
  /// grants (phases 2 and 3) cap what it may do by the person's current permissions instead.
  Member? _memberFor(OidcIdentity who) {
    final family = hub.den.familyId;
    if (!hub.ready || family == null) return null;
    final m = hub.den.memberWithAccount(AccountRef(who.provider, accountHash(family, who.provider, who.sub)));
    return m != null && m.isParent ? m : null;
  }

  Response _signIn(Request r, OidcIdentity who, OidcProvider p) {
    final member = _memberFor(who);
    if (member == null) {
      hub.log.info('A sign-in with ${p.name} matched nobody in the family');
      return noAccountPage();
    }
    // A new session for each sign-in; whatever this browser held before ends now.
    for (final old in cookieValues(r, sessionCookie)) {
      _sessions.remove(_sha(old));
    }
    final token = randomToken();
    _sessions[_sha(token)] = _Session(member: member.id, account: member.account!, created: hub.now());
    while (_sessions.length > maxSessions) {
      _sessions.remove(_sessions.keys.first);
    }
    hub.log.info('${member.name} signed in with ${p.name}');
    final family = hub.den.family?.name;
    return _page(
      200,
      'Signed in',
      'You\'re signed in to ${family == null ? 'Den' : '$family\'s Den'} as ${member.name}.',
      headers: {
        'set-cookie': [_cookie(sessionCookie, token, sessionLifetime), _expire(flowCookie)],
      },
      link: true,
    );
  }

  /// Finishes binding [b] with [who]: the hub's proof that [who] signed in for [b]'s member
  /// ([AccountProof], signed with the hub's device key), which the phone writes with the record.
  /// A binding is finished once: a second sign-in spoils it (finding F1).
  Future<Response> _bind(_Binding b, OidcIdentity who, OidcProvider p) async {
    final family = hub.den.familyId;
    final member = hub.den.member(b.member);
    bool over() => _bindings[b.id] != b || b.expired(hub.now()) || b.failure != null;
    if (over() || !hub.ready || family == null || member == null) return _expired();
    if (b.result != null) {
      b.fail('That sign-in came back twice, so it doesn\'t bind anything. Start again in Den.');
      return _expired();
    }
    final hash = accountHash(family, who.provider, who.sub);
    final holder = hub.den.memberWithAccount(AccountRef(who.provider, hash));
    if (holder != null && holder.id != b.member) {
      b.fail('That ${p.name} account already signs in as someone else in the family.');
      return _page(409, 'That account is someone else\'s', 'It already signs in as someone else in your family. Go back to Den and '
          'choose another.', headers: _clearFlow);
    }
    final account = await AccountProof.sign(
      keys: hub.den.keys,
      hub: hub.den.deviceId,
      family: family,
      member: b.member,
      provider: who.provider,
      hash: hash,
      nonce: randomToken(),
      expires: hub.now() + accountProofLife.inMilliseconds,
    );
    if (over()) return _expired();
    if (b.result != null) {
      b.fail('That sign-in came back twice, so it doesn\'t bind anything. Start again in Den.');
      return _expired();
    }
    b.result = _Bound(account, who.email);
    hub.log.info('${member.name} signed in with ${p.name} to bind it; their phone finishes that');
    return _page(200, 'Now back to Den', 'You signed in with ${p.name} as ${who.email}. Go back to Den on your phone to finish.',
        headers: _clearFlow);
  }

  /// `POST /auth/logout`, from Den's own pages only (`Origin`): ends this browser's session.
  Future<Response> logout(Request r) async {
    final origin = r.headers['origin'];
    if (origin == null || origin != hub.config.publicUrl!.origin) {
      hub.failed(r);
      throw ApiError.denied('Sign out from Den\'s own page.');
    }
    for (final t in cookieValues(r, sessionCookie)) {
      _sessions.remove(_sha(t));
    }
    return jsonResponse({'ok': true}, headers: {'set-cookie': _expire(sessionCookie)});
  }

  /// `GET /api/v1/me`: who this browser is signed in as. `401` without a session.
  Response me(Request r) {
    final found = _session(r);
    if (found == null) throw ApiError(401, 'unauthorized', 'Sign in with Google or Apple first.');
    final (s, m) = found;
    return jsonResponse({
      'member': {'id': m.id, 'name': m.name, 'role': m.role.name},
      'provider': s.account.provider,
      'family': {'id': hub.den.familyId, 'name': hub.den.family?.name},
      'signed_in_ms': s.created,
      'expires_ms': s.expires,
    });
  }

  /// The session [r]'s cookie names, with its member: none when the cookie is missing, sent twice
  /// or unknown, the session is over, or the member no longer has the account it signed in with
  /// or is no longer a parent (either ends it).
  (_Session, Member)? _session(Request r) {
    final token = cookie(r, sessionCookie);
    if (token == null) return null;
    final key = _sha(token);
    final s = _sessions[key];
    if (s == null) return null;
    final m = hub.ready ? hub.den.member(s.member) : null;
    if (hub.now() >= s.expires || m == null || m.account != s.account || !m.isParent) {
      _sessions.remove(key);
      return null;
    }
    return (s, m);
  }

  // ------------------------------------------------------------------ the parent's phone

  /// [c], for a parent on their own personal phone: the only place an account is bound.
  static DeviceRequestCheck _ownPhone(DeviceRequestCheck c) {
    const message = 'Only a parent\'s own phone can set up signing in with Google or Apple.';
    DeviceAuth.parentOf(c, message: message);
    if (c.device!.mode != DeviceMode.personal) throw ApiError.denied(message);
    return c;
  }

  /// `GET /api/v1/account/providers`, signed by a parent's own phone: what this hub signs in with.
  Future<Response> listProviders(Request r) async {
    _ownPhone(await auth.check(r));
    return jsonResponse({
      'providers': [
        for (final p in providers!.all) {'id': p.id, 'name': p.name},
      ],
    });
  }

  /// `POST /api/v1/account/bindings {"provider": "google"}`, signed by a parent's own phone:
  /// starts binding their account. Answers the `id` the phone reads the result back by and the
  /// `start_url` it opens in a browser (once).
  Future<Response> createBinding(Request r) async {
    final signed = await auth.withBody(r, limit: 1024);
    final c = _ownPhone(signed.check);
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(signed.body));
    } on FormatException {
      throw ApiError.invalid('The body must be a JSON object.');
    }
    final asked = json is Map ? json['provider'] : null;
    final provider = providers!.byId(asked is String ? asked : null);
    if (provider == null) {
      throw ApiError.invalid('This hub signs in with ${providers!.all.map((p) => p.id).join(' or ')}.', field: 'provider');
    }
    final now = hub.now();
    _prune(now);
    final device = c.device!.id;
    if (_bindings.values.where((b) => b.device == device).length >= maxBindingsPerDevice) {
      throw ApiError.rateLimited(bindingLifetime.inSeconds, 'Finish the sign-in you started, or wait a few minutes.');
    }
    if (_bindings.length >= maxBindings) throw ApiError(429, 'busy', 'The hub is busy. Try again in a few minutes.');
    final id = randomToken(), ticket = randomToken();
    final b = _Binding(id: _sha(id), ticket: _sha(ticket), device: device, member: c.actor!.id, provider: provider.id, created: now);
    _bindings[b.id] = b;
    _tickets[b.ticket] = b;
    return jsonResponse({
      'id': id,
      'provider': provider.id,
      'start_url': '${urlOf(hub.config.publicUrl!, '/auth/oidc/${provider.id}/start')}?bind=$ticket',
      'expires_ms': now + bindingLifetime.inMilliseconds,
    }, status: 201);
  }

  /// `GET /api/v1/account/bindings/<id>`, signed by the phone that started it, for the same
  /// parent: `waiting`, `failed` (with a message), or `done` with the `account` to write into
  /// `member.account` and the email signed in with. A result is given once; then it is gone.
  Future<Response> pollBinding(Request r, String id) async {
    final c = _ownPhone(await auth.check(r));
    final now = hub.now();
    final b = _bindings[_sha(id)];
    if (b == null || b.device != c.device!.id || b.member != c.actor!.id || b.expired(now)) {
      if (b != null && b.expired(now)) _drop(b);
      throw ApiError.notFound(type: 'binding', message: 'That sign-in expired. Start again.');
    }
    final failure = b.failure;
    if (failure != null) {
      _drop(b);
      return jsonResponse({'state': 'failed', 'message': failure});
    }
    final result = b.result;
    if (result == null) return jsonResponse({'state': 'waiting', 'expires_ms': b.created + bindingLifetime.inMilliseconds});
    _drop(b);
    return jsonResponse({'state': 'done', 'account': result.account.toJson(), 'email': result.email});
  }

  void _drop(_Binding b) {
    _bindings.remove(b.id);
    _tickets.remove(b.ticket);
  }

  void _prune(int now) {
    _flows.removeWhere((_, f) => f.expired(now));
    _sessions.removeWhere((_, s) => now >= s.expires);
    final gone = [for (final b in _bindings.values) if (b.expired(now)) b];
    gone.forEach(_drop);
  }

  // ------------------------------------------------------------------ cookies and pages

  static String _sha(String value) =>
      [for (final b in const DartSha256().hashSync(utf8.encode(value)).bytes) b.toRadixString(16).padLeft(2, '0')].join();

  /// A `__Host-` cookie: `Secure`, no `Domain`, `Path=/`, and `HttpOnly`, `SameSite=Lax`.
  static String _cookie(String name, String value, Duration life) =>
      '$name=$value; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=${life.inSeconds}';

  static String _expire(String name) => '$name=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0';

  static final Map<String, Object> _clearFlow = {'set-cookie': _expire(flowCookie)};

  /// Every value [r] sends for the cookie [name].
  static List<String> cookieValues(Request r, String name) => [
        for (final header in r.headersAll['cookie'] ?? const <String>[])
          for (final part in header.split(';'))
            if (part.contains('=') && part.substring(0, part.indexOf('=')).trim() == name) part.substring(part.indexOf('=') + 1).trim(),
      ];

  /// The one value [r] sends for the cookie [name]; null for none, or for more than one (a
  /// cookie can't be planted beside a `__Host-` one from elsewhere, but if two arrive, neither
  /// counts).
  static String? cookie(Request r, String name) {
    final values = cookieValues(r, name);
    if (values.length != 1 || values.single.isEmpty || values.single.length > 200) return null;
    return values.single;
  }

  /// The one answer to an account that is bound to nobody in this family, whether the hub is in
  /// a family yet or not (and, in phase 3, whether an invite exists or not): the same status,
  /// the same bytes, after the same work (the code exchanged and the token checked), and nothing
  /// made.
  Response noAccountPage() => _page(403, 'Den couldn\'t sign you in',
      'That account isn\'t set up for this family\'s Den. If your family uses Den, ask a parent to set you up.',
      headers: _clearFlow);

  Response _expired() => _page(400, 'This sign-in expired', 'It was already used, or took too long. Start again.', headers: _clearFlow);

  Response _failed() => _page(400, 'Den couldn\'t sign you in', 'Something about that sign-in didn\'t check out. Start again.',
      headers: _clearFlow);

  Response _unavailable(OidcProvider p) => _page(503, '${p.name} sign-in isn\'t working',
      'Den couldn\'t reach ${p.name}. Try again in a few minutes.',
      headers: {..._clearFlow, 'retry-after': '60'});

  static const HtmlEscape _html = HtmlEscape();
  static const HtmlEscape _attribute = HtmlEscape(HtmlEscapeMode.attribute);

  late final String _style = _styleFor(hub.config.webDir);
  String _policy({bool form = false}) => [
        "default-src 'none'",
        "style-src 'sha256-${base64.encode(const DartSha256().hashSync(utf8.encode(_style)).bytes)}'",
        "font-src 'self'",
        "img-src 'self'",
        "base-uri 'none'",
        "form-action ${form ? "'self'" : "'none'"}",
        "frame-ancestors 'none'",
      ].join('; ');

  /// A page for people, in Den's design tokens like the OAuth pages, with no script: its one
  /// style is allowed by its hash, so the same page is the same bytes every time.
  Response _page(
    int status,
    String heading,
    String message, {
    Map<String, Object> headers = const {},
    bool link = false,
    ({String action, Map<String, String> fields, String label})? form,
  }) {
    final button = form == null
        ? ''
        : '<form method="post" action="${_attribute.convert(form.action)}">\n'
            '${[for (final e in form.fields.entries) '<input type="hidden" name="${_attribute.convert(e.key)}" value="${_attribute.convert(e.value)}">\n'].join()}'
            '<button type="submit">${_html.convert(form.label)}</button>\n</form>\n';
    final body = '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>${_html.convert(heading)}</title>
<style>$_style</style>
</head>
<body>
<main>
<h1>${_html.convert(heading)}</h1>
<p>${_html.convert(message)}</p>
${link ? '<p><a href="/">Open Den</a></p>\n' : ''}$button</main>
</body>
</html>''';
    return Response(status, body: body, headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'content-security-policy': _policy(form: form != null),
      ...headers,
    });
  }

  static String _styleFor(String? webDir) {
    final sep = Platform.pathSeparator;
    final font = webDir != null && File('$webDir${sep}assets${sep}assets${sep}fonts${sep}AtkinsonHyperlegibleNext.ttf').existsSync()
        ? "@font-face{font-family:'Atkinson Hyperlegible Next';src:url('/assets/assets/fonts/AtkinsonHyperlegibleNext.ttf');}"
        : '';
    return '$font'
        ':root{--paper:#F2F2F2;--ink:#141414;--ink2:#595959;color-scheme:light dark;}'
        '@media (prefers-color-scheme: dark){:root{--paper:#000000;--ink:#F2F2F2;--ink2:#A6A6A6;}}'
        "body{margin:0;background:var(--paper);color:var(--ink);font-family:'Atkinson Hyperlegible Next',system-ui,-apple-system,'Segoe UI',sans-serif;font-size:17px;line-height:1.35;}"
        'main{max-width:480px;margin:0 auto;padding:48px 16px;}'
        'h1{font-size:26px;font-weight:800;line-height:1.2;margin:0 0 16px;}'
        'p{margin:0 0 12px;}'
        'a{color:var(--ink);font-weight:700;}'
        'button{font:inherit;font-weight:700;color:var(--paper);background:var(--ink);border:0;border-radius:24px;'
        'padding:12px 20px;margin-top:12px;min-height:48px;cursor:pointer;}';
  }
}
