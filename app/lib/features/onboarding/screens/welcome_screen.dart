import 'dart:async';

import 'package:den_net/den_net.dart' show DenLink, DenLinkKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/mark.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/pairing.dart';
import '../../../platform/web/passkey_button.dart';
import '../../../platform/web/passkeys.dart';
import '../../../platform/web/web_app.dart';
import '../state/demo_session.dart';
import '../state/this_device.dart';
import 'home_screen_steps.dart';

/// The first screen on a device with no family, when no link opened Den: the task, as plain
/// rows. A link opens the step it is for instead (an invite opens Join, a setup link Start), so
/// most people never see this screen.
///
/// In a browser the hub served, the rows follow the hub: a fresh hub offers to start the family
/// here (this browser becomes the founding parent's device and takes the hub in with its setup
/// code); a hub already in a family offers to join it, or to set this device up as a kitchen
/// screen with a code a parent types on their phone. Paste an invite takes a link copied in
/// Safari, which is how a link reaches a Home Screen app that is already there. Safari on an
/// iPhone or iPad first shows how to put Den on the Home Screen, where the family should live.
///
/// Someone who was in the family before (Safari cleared the Home Screen app, or a new phone)
/// signs back in with their passkey: "Sign in with Face ID" is the page's one primary button,
/// wherever the browser can (an https address; on plain http at home it isn't there, and
/// nothing says why), with "Lost your phone? Use your recovery words" under the rows. The hub's
/// challenge is fetched as the page opens and armed in the page, so the tap opens the passkey
/// sheet at once (see [PasskeyButton]).
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, this.browser, this.hub, this.web, this.passkeys});

  /// Shows the browser's choices, for tests; by default only on the web.
  final bool? browser;

  /// The hub that served the page, for tests; by default asked of the hub.
  final HubInfo? hub;

  /// The browser, for tests; by default read from the page.
  final WebAppInfo? web;

  /// The browser's passkeys, for tests; by default the page's.
  final PasskeyBrowser? passkeys;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _startingDemo = false;
  bool _inSafari = false;
  String? _error;
  String? _pasteError;
  HubInfo? _hub;
  bool _asked = false;

  /// In a browser, whether the hub has answered (or 2 seconds passed): until then the page stays
  /// blank, so the rows don't change under the person's finger once it does.
  bool _settled = false;
  Timer? _wait;

  /// A passkey challenge is armed in the page: the button opens the sheet at once.
  bool _armed = false;

  /// Whether the hub offers passkeys at this address, once it said (an older hub, or a page
  /// cached from before them, doesn't): until then the button waits; without, it isn't there.
  bool? _hubOffers;
  bool _arming = false;
  bool _signingIn = false;
  String? _signInError;
  Timer? _rearm;

  bool get _browser => widget.browser ?? Capabilities.web;

  PasskeyBrowser get _passkeys => widget.passkeys ?? PasskeyBrowser.current;

  /// Signing in with a passkey is offered: a browser that can, at a hub that is in a family.
  bool _offersPasskey(HubInfo? hub) => _browser && _passkeys.available && hub != null && hub.paired;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked || !_browser) return;
    _asked = true;
    _hub = widget.hub;
    if (_hub == null) {
      _wait = Timer(const Duration(seconds: 2), () {
        if (mounted && !_settled) setState(() => _settled = true);
      });
      Pairing.of(context).servingHub().then((hub) {
        if (!mounted) return;
        _wait?.cancel();
        setState(() {
          _hub = hub;
          _settled = true;
        });
        // A fresh hub on the home network is this browser's to set up: straight to it.
        if (hub != null && hub.open && !hub.paired) {
          context.go('/welcome/start');
          return;
        }
        _arm();
      });
    } else {
      _settled = true;
      _arm();
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _rearm?.cancel();
    super.dispose();
  }

  /// Fetches a sign-in challenge and arms it in the page, ahead of the tap; again before it runs
  /// out, and after each try (a challenge works once).
  Future<void> _arm() async {
    _rearm?.cancel();
    if (!_offersPasskey(_hub) || _arming) return;
    _arming = true;
    final options = await Pairing.of(context).passkeySignInOptions();
    _arming = false;
    if (!mounted) return;
    final ok = options != null && options['rpId'] == _passkeys.host && _passkeys.arm(PasskeyKind.get, options);
    setState(() {
      _armed = ok;
      _hubOffers ??= ok;
    });
    // The hub's challenge lasts five minutes.
    _rearm = Timer(const Duration(minutes: 4), _arm);
  }

  /// What the passkey sheet answered: the hub says who it is, and this device joins as them.
  Future<void> _signedIn(PasskeyOutcome outcome) async {
    setState(() {
      _armed = false;
      _signInError = null;
    });
    switch (outcome) {
      case PasskeyRefused(cancelled: true):
        // Closed, or it timed out: nothing to say.
        unawaited(_arm());
        return;
      case PasskeyRefused():
        setState(() => _signInError = "That didn't work. Try again.");
        unawaited(_arm());
        return;
      case PasskeyAnswer(:final credential):
        setState(() => _signingIn = true);
        final web = widget.web ?? WebApp.info;
        try {
          final ticket = await Pairing.of(context).signInWithPasskey(
            credential,
            deviceName: (name) => suggestNewDeviceName(name, web.kind),
            kind: web.kind,
          );
          Pairing.ticket = ticket;
          if (mounted) context.go('/welcome/waiting');
        } on PairingException catch (e) {
          if (!mounted) return;
          setState(() {
            _signingIn = false;
            _signInError = e.message;
          });
          unawaited(_arm());
        }
    }
  }

  Future<void> _demo() async {
    setState(() {
      _startingDemo = true;
      _error = null;
    });
    try {
      await DemoSession.start(context);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _startingDemo = false;
        _error = "Couldn't open the demo family: $e";
      });
    }
  }

  /// Opens the step a link copied in Safari is for. Called straight from the tap, so a browser
  /// lets it read the clipboard.
  Future<void> _paste() async {
    final pasted = await WebApp.paste();
    String? text = pasted.text;
    if (text == null) {
      try {
        text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      } on Object {
        text = null;
      }
    }
    if (!mounted) return;
    final link = DenLink.parse(text ?? '');
    final String? problem = switch (link?.kind) {
      null => "There's no invite on the clipboard. In Safari, tap Copy invite, then come back and tap Paste again.",
      DenLinkKind.group => 'Invites to a group of families come with a later version of Den.',
      _ => null,
    };
    setState(() => _pasteError = problem);
    if (problem != null) return;
    context.go(switch (link!.kind) {
      DenLinkKind.setup => Uri(path: '/welcome/start', queryParameters: {'setup': link.code, 'hub': ?link.hubDevice}).toString(),
      DenLinkKind.recover => Uri(path: '/welcome/recover', queryParameters: {'code': link.words}).toString(),
      _ => Uri(path: '/welcome/join', queryParameters: {'code': link.words}).toString(),
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_browser && !_settled) return ColoredBox(color: context.colors.bg, child: const SizedBox.expand());
    final web = widget.web ?? WebApp.info;
    final hub = _hub;
    final steps = _browser && web.needsHomeScreen && !_inSafari;
    // A hub already in a family can't be started again: this browser joins it. A fresh one
    // waits for the family started here. When the hub doesn't answer, offer both.
    final canStart = !_browser || hub == null || !hub.paired;
    final canJoin = !_browser || hub == null || hub.paired;
    final passkey = !steps && _offersPasskey(hub) && _hubOffers != false;
    return DenPage(
      // A family's own address: someone here to join it or to get back in, not to set Den up.
      title: _browser && hub != null && hub.paired ? 'Welcome to Den' : 'Set up Den',
      back: false,
      trailing: const DenMark(size: 44),
      bottom: passkey
          ? PasskeyButton(
              kind: PasskeyKind.get,
              label: PasskeyWords.of(web).signIn,
              busyLabel: 'Signing in',
              ready: _armed,
              busy: _signingIn,
              browser: widget.passkeys,
              onResult: _signedIn,
            )
          : null,
      children: [
        if (steps) ...[
          HomeScreenSteps(ipad: web.ipad),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => setState(() => _inSafari = true), child: const Text('Use Den in Safari instead')),
          ),
        ] else ...[
          GroupCard(
            child: Column(
              children: ruled([
                if (canStart)
                  NavRow(
                    icon: PhosphorIconsRegular.houseLine,
                    label: 'Start a family',
                    detail: 'You set it up and invite the others',
                    onTap: () => context.go('/welcome/start'),
                  ),
                if (canJoin)
                  NavRow(
                    icon: _browser ? PhosphorIconsRegular.chatCircleText : PhosphorIconsRegular.qrCode,
                    label: 'Join your family',
                    detail: 'With the invite a parent sent you',
                    onTap: () => context.go('/welcome/join'),
                  ),
                if (canJoin)
                  NavRow(
                    icon: PhosphorIconsRegular.monitor,
                    label: 'Set up as a kitchen screen',
                    detail: 'A parent adds it with a code',
                    onTap: () => context.go('/welcome/screen'),
                  ),
                NavRow(
                  icon: PhosphorIconsRegular.clipboardText,
                  label: 'Paste an invite',
                  detail: 'One you copied from a message or from Safari',
                  chevron: false,
                  onTap: _paste,
                ),
                if (_browser && (!web.ios || web.ipad) && hub != null && hub.paired)
                  NavRow(
                    icon: PhosphorIconsRegular.browser,
                    label: 'Already in the family? Link this browser',
                    detail: "Scan the code it shows with a parent's phone",
                    onTap: () => context.go('/welcome/link'),
                  ),
              ], indent: 36),
            ),
          ),
          if (_pasteError != null) Text(_pasteError!, style: context.text.meta(context.colors.destructive)),
          if (passkey) ...[
            if (_signInError != null) Text(_signInError!, style: context.text.meta(context.colors.destructive)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => context.push('/welcome/recover'),
                child: const Text('Lost your phone? Use your recovery words'),
              ),
            ),
          ],
          GroupCard(
            child: NavRow(
              icon: PhosphorIconsRegular.usersThree,
              label: _startingDemo ? 'Opening the demo family' : 'Look around with a demo family',
              onTap: _startingDemo ? null : _demo,
            ),
          ),
          if (_error != null) ErrorState(message: _error!, actionLabel: 'Try again', onAction: _demo),
        ],
      ],
    );
  }
}
