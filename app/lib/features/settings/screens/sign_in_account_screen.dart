import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/hub_client.dart';
import '../../family/family.dart';
import '../state/account_sign_in.dart';

export '../state/account_sign_in.dart';

/// Settings → Google or Apple sign-in, on a parent's own phone: which account signs in to the
/// family's Den as them, and setting one up. "Sign in with Google" asks the family's hub for a
/// sign-in and opens it in the browser; once it's done there, this phone reads the result back
/// from the hub (once), says which account it was, and on the parent's OK binds it to them
/// itself. The hub never binds an account: only this phone may (validity.dart). The account is
/// matched by the provider's own id for it, never by its email.
class SignInAccountScreen extends StatefulWidget {
  const SignInAccountScreen({super.key, this.source, this.open, this.pollEvery = const Duration(seconds: 2)});

  /// The hub's side; tests pass a fake.
  final AccountSignInSource? source;

  /// Opens the sign-in page in a browser; tests pass their own.
  final Future<bool> Function(Uri url)? open;

  /// How often it asks the hub how the sign-in went.
  final Duration pollEvery;

  @override
  State<SignInAccountScreen> createState() => _SignInAccountScreenState();
}

class _SignInAccountScreenState extends State<SignInAccountScreen> {
  AccountSignInSource? _source;
  List<SignInProvider>? _providers;
  String? _error;
  bool _busy = false;
  bool _started = false;

  /// A sign-in under way in the browser.
  BindingStart? _waiting;

  /// The page didn't open by itself (a browser blocks it after a wait): a button opens it.
  bool _openByHand = false;

  /// What the browser signed in as, waiting for the parent's OK.
  BindingDone? _found;

  /// The email just bound, shown until the page closes (the family's log never holds it).
  String? _boundEmail;
  bool _removing = false;
  Timer? _poll;
  DateTime? _gaveUpAt;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final network = context.watch(const {}).network;
    final hasHub = network != null && (network.isHub || network.hubDevice != null);
    _source = widget.source ?? (hasHub ? HubAccountSignIn(network) : null);
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final source = _source;
    if (source == null) {
      setState(() => _providers = const []);
      return;
    }
    try {
      final found = await source.providers();
      if (mounted) {
        setState(() {
          _providers = found;
          _error = null;
        });
      }
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<bool> _openPage(Uri url) =>
      (widget.open ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank'))(url);

  Future<void> _start(SignInProvider provider) async {
    setState(() {
      _busy = true;
      _error = null;
      _found = null;
      _openByHand = false;
    });
    try {
      final started = await _source!.start(provider.id);
      if (!mounted) return;
      setState(() {
        _waiting = started;
        _busy = false;
      });
      _gaveUpAt = DateTime.now().add(const Duration(minutes: 10));
      _poll?.cancel();
      _poll = Timer.periodic(widget.pollEvery, (_) => _check());
      final opened = await _openPage(started.startUrl);
      if (!opened && mounted) setState(() => _openByHand = true);
    } on HubException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  bool _checking = false;

  Future<void> _check() async {
    final waiting = _waiting;
    if (waiting == null || _checking) return;
    if (DateTime.now().isAfter(_gaveUpAt!)) {
      _stop(error: 'That sign-in took too long. Start again.');
      return;
    }
    _checking = true;
    try {
      final state = await _source!.poll(waiting.id);
      if (!mounted || _waiting != waiting) return;
      switch (state) {
        case BindingWaiting():
          break;
        case BindingFailed(:final message):
          _stop(error: message);
        case final BindingDone done:
          _stop();
          setState(() => _found = done);
      }
    } on HubException {
      // The hub didn't answer this time; the next tick asks again.
    } finally {
      _checking = false;
    }
  }

  void _stop({String? error}) {
    _poll?.cancel();
    _poll = null;
    if (!mounted) return;
    setState(() {
      _waiting = null;
      _openByHand = false;
      _error = error;
    });
  }

  Future<void> _bind(Member me, BindingDone done) async {
    final trust = context.trustActions;
    setState(() => _busy = true);
    final problem = await tryWrite(() => trust.setAccount(me.id, done.account));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
      if (problem == null) {
        _found = null;
        _boundEmail = done.email;
      }
    });
  }

  Future<void> _unbind(Member me) async {
    final trust = context.trustActions;
    setState(() => _busy = true);
    final problem = await tryWrite(() => trust.setAccount(me.id, null));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
      if (problem == null) {
        _removing = false;
        _boundEmail = null;
      }
    });
  }

  String _name(String provider) => provider == 'apple' ? 'Apple' : 'Google';

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.member});
    final c = context.colors;
    final t = context.text;
    final me = app.me;
    final account = me?.account;
    final providers = _providers;
    final found = _found;
    final waiting = _waiting;

    return DenPage(
      title: 'Google or Apple sign-in',
      children: [
        Text(
          'Sign in to your family\'s Den in a browser with your Google or Apple account. Den knows the account by the '
          'account itself, not its email.',
          style: t.body(c.ink2),
        ),
        if (account != null && app.den.sharedAccounts().any((list) => list.any((m) => m.id == me?.id)))
          const AttentionLine(
            message: 'Someone else in the family has this account too, so it signs in as neither of you. Whoever it '
                'isn\'t takes it away.',
            bad: true,
          ),
        GroupCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: Row(
                  children: [
                    Icon(
                      account == null
                          ? PhosphorIconsRegular.userCircle
                          : account.provider == 'apple'
                              ? PhosphorIconsRegular.appleLogo
                              : PhosphorIconsRegular.googleLogo,
                      size: 22,
                      color: c.ink,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(account == null ? 'No account yet' : 'Your ${_name(account.provider)} account', style: t.body(c.ink)),
                          Text(
                            account == null ? 'Nobody signs in as you with Google or Apple' : _boundEmail ?? 'Signs in as you',
                            style: t.meta(c.ink2),
                          ),
                        ],
                      ),
                    ),
                    if (account != null && me != null && !_removing)
                      TextButton(
                        onPressed: _busy ? null : () => setState(() => _removing = true),
                        style: TextButton.styleFrom(foregroundColor: c.destructive),
                        child: const Text('Remove'),
                      ),
                  ],
                ),
              ),
              DenReveal(
                visible: _removing,
                child: !_removing || me == null
                    ? const SizedBox(width: double.infinity)
                    : ConfirmPanel(
                        message: 'That account no longer signs in as you, and a browser signed in with it is signed out.',
                        confirmLabel: 'Remove it',
                        destructive: true,
                        busy: _busy,
                        error: _error,
                        onConfirm: () => _unbind(me),
                        onCancel: () => setState(() => _removing = false),
                      ),
              ),
            ],
          ),
        ),
        if (found != null && me != null)
          GroupCard(
            child: ConfirmPanel(
              message: 'Sign in to Den as you with ${found.email} (${_name(found.account.provider)})? Whoever has that '
                  'account can then sign in as you.',
              confirmLabel: 'Use this account',
              busy: _busy,
              error: _error,
              onConfirm: () => _bind(me, found),
              onCancel: () => setState(() => _found = null),
            ),
          )
        else if (waiting != null)
          GroupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const NoticeLine(icon: PhosphorIconsRegular.hourglass, message: 'Finish signing in in your browser, then come back here.'),
                Wrap(
                  spacing: Sp.s,
                  children: [
                    if (_openByHand)
                      OutlinedButton(onPressed: () => _openPage(waiting.startUrl), child: const Text('Open the sign-in page')),
                    TextButton(onPressed: () => _stop(), child: const Text('Cancel')),
                  ],
                ),
                const SizedBox(height: Sp.s),
              ],
            ),
          )
        else if (_error != null && providers != null && providers.isNotEmpty && !_removing)
          GroupCard(child: ErrorState(message: _error!, actionLabel: 'OK', onAction: () => setState(() => _error = null))),
        if (_error != null && providers == null)
          GroupCard(child: ErrorState(message: _error!, actionLabel: 'Try again', onAction: _load))
        else if (providers == null)
          const NoticeLine(icon: PhosphorIconsRegular.hourglass, message: 'Asking the hub')
        else if (providers.isEmpty)
          const NoticeLine(
            icon: PhosphorIconsRegular.info,
            message: 'Your family\'s hub doesn\'t offer signing in with Google or Apple yet. Whoever runs it can turn it on.',
          )
        else if (waiting == null && found == null)
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              for (final p in providers)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _start(p),
                  icon: Icon(p.id == 'apple' ? PhosphorIconsRegular.appleLogo : PhosphorIconsRegular.googleLogo, size: 20),
                  label: Text(account?.provider == p.id ? 'Use another ${p.name} account' : 'Sign in with ${p.name}'),
                ),
            ],
          ),
      ],
    );
  }
}
