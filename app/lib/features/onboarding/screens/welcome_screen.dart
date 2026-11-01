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
import '../../../platform/web/web_app.dart';
import '../state/demo_session.dart';
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
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, this.browser, this.hub, this.web});

  /// Shows the browser's choices, for tests; by default only on the web.
  final bool? browser;

  /// The hub that served the page, for tests; by default asked of the hub.
  final HubInfo? hub;

  /// The browser, for tests; by default read from the page.
  final WebAppInfo? web;

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

  bool get _browser => widget.browser ?? Capabilities.web;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked || !_browser) return;
    _asked = true;
    _hub = widget.hub;
    if (_hub == null) {
      Pairing.of(context).servingHub().then((hub) {
        if (mounted) setState(() => _hub = hub);
      });
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
    final web = widget.web ?? WebApp.info;
    final hub = _hub;
    final steps = _browser && web.needsHomeScreen && !_inSafari;
    // A hub already in a family can't be started again: this browser joins it. A fresh one
    // waits for the family started here. When the hub doesn't answer, offer both.
    final canStart = !_browser || hub == null || !hub.paired;
    final canJoin = !_browser || hub == null || hub.paired;
    return DenPage(
      title: 'Set up Den',
      back: false,
      trailing: const DenMark(size: 44),
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
                if (_browser && !web.ios && hub != null && hub.paired)
                  NavRow(
                    icon: PhosphorIconsRegular.browser,
                    label: "Link with a parent's phone",
                    detail: 'Show a code to scan, for a computer in the house',
                    onTap: () => context.go('/welcome/link'),
                  ),
              ], indent: 36),
            ),
          ),
          if (_pasteError != null) Text(_pasteError!, style: context.text.meta(context.colors.destructive)),
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
