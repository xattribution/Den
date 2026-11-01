import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/web/passkey_button.dart';
import '../../../platform/web/passkeys.dart';
import '../../../platform/web/web_app.dart';
import '../../family/state/passkeys.dart';
import '../../family/widgets/passkey_section.dart';

/// Right after someone joins on their own phone, in a browser that can: "Use Face ID to get back
/// in" (a fingerprint or the screen lock on Android, a passkey elsewhere). One tap makes the
/// passkey; Not now goes on to Today, and their page in Family offers it again. Someone who
/// has one already, or a browser that can't, goes straight on.
class PasskeyOfferScreen extends StatefulWidget {
  const PasskeyOfferScreen({super.key, this.source, this.browser, this.web});

  /// The hub, for tests; by default this device's.
  final PasskeySource? source;

  /// The browser, for tests.
  final PasskeyBrowser? browser;
  final WebAppInfo? web;

  @override
  State<PasskeyOfferScreen> createState() => _PasskeyOfferScreenState();
}

class _PasskeyOfferScreenState extends State<PasskeyOfferScreen> {
  PasskeyMaker? _maker;
  bool _left = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_maker != null || _left) return;
    final app = DenScope.read(context);
    final source = widget.source ?? (PasskeyHub.reachable(app) ? PasskeyHub.source(app) : null);
    if (source == null || !canMakePasskey(app, browser: widget.browser)) {
      _leave();
      return;
    }
    _maker = PasskeyMaker(source: source, browser: widget.browser ?? PasskeyBrowser.current)..addListener(_changed);
    _maker!.prepare().then((_) {
      final maker = _maker;
      // Nothing to offer: this browser can't here after all, or they have one already.
      if (maker != null && (maker.unavailable || maker.existing > 0)) _leave();
    });
  }

  @override
  void dispose() {
    _maker?.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _leave() {
    if (_left) return;
    _left = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.go('/today');
    });
  }

  Future<void> _answered(PasskeyOutcome outcome) async {
    final app = DenScope.read(context);
    await _maker!.answered(outcome, after: () => letHubHelpWithPasskey(context, app));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final web = widget.web ?? (widget.browser ?? PasskeyBrowser.current).info;
    final words = PasskeyWords.of(web);
    final maker = _maker;
    final app = context.watch(const {});
    final parent = app.me?.isParent ?? false;
    final device = web.ios ? (web.ipad ? 'iPad' : 'iPhone') : web.android ? 'phone' : 'device';
    final done = maker?.done ?? false;
    return DenPage(
      title: words.offer,
      back: false,
      bottom: done
          ? FilledButton(
              onPressed: () => context.go('/today'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: const Text('Continue'),
            )
          : PasskeyButton(
              kind: PasskeyKind.create,
              label: words.make,
              busyLabel: 'Setting it up',
              ready: maker?.ready ?? false,
              busy: maker?.busy ?? false,
              browser: widget.browser,
              onResult: _answered,
            ),
      children: [
        Text(
          parent
              ? 'If this $device is reset or Den is cleared, ${words.what} lets you straight back in. No words to keep. '
                  "The hub checks it, and everyone in the family can see when it's used."
              : "If this $device is reset or Den is cleared, ${words.what} tells your family it's you, and a parent "
                  'lets you back in with one tap.',
          style: t.body(c.ink2),
        ),
        if (done)
          NoticeLine(
            icon: PhosphorIconsRegular.check,
            message: maker!.already ? 'This $device has your passkey already.' : words.done,
          ),
        if (maker?.error != null) Text(maker!.error!, style: t.meta(c.destructive)),
        if (!done)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.s),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: maker?.busy ?? false ? null : () => context.go('/today'),
                child: const Text('Not now'),
              ),
            ),
          ),
      ],
    );
  }
}
