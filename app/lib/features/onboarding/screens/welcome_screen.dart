import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/mark.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/pairing.dart';
import '../../../platform/web/web_app.dart';
import '../state/demo_session.dart';
import 'home_screen_steps.dart';

/// The first screen on a device with no family: the task, as plain rows.
///
/// In a browser the hub served, the rows follow the hub: a fresh hub offers to start the family
/// here (this browser becomes the founding parent's device and takes the hub in with its setup
/// code); a hub already in a family offers to join it. Safari on an iPhone or iPad first shows
/// how to put Den on the Home Screen, where the family should live.
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
                if (_browser && !web.ios && hub != null && hub.paired)
                  NavRow(
                    icon: PhosphorIconsRegular.browser,
                    label: "Link with a parent's phone",
                    detail: 'For a computer in the house',
                    onTap: () => context.go('/welcome/link'),
                  ),
              ], indent: 36),
            ),
          ),
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
