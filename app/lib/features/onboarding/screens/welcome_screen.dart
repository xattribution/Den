import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/mark.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/pairing.dart';
import '../../../platform/web/web_app.dart';
import '../state/demo_session.dart';
import 'home_screen_steps.dart';
import '../../../platform/capabilities.dart';

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
    setState(() => _startingDemo = true);
    try {
      await DemoSession.start(context);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _startingDemo = false);
      showNote(context, "Couldn't open the demo family: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final web = widget.web ?? WebApp.info;
    final hub = _hub;
    final steps = _browser && web.needsHomeScreen && !_inSafari;
    // A hub already in a family can't be started again: this browser joins it. A fresh one
    // waits for the family started here. When the hub doesn't answer, offer both.
    final canStart = !_browser || hub == null || !hub.paired;
    final canJoin = !_browser || hub == null || hub.paired;
    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.only(top: Sp.xxxl, bottom: Sp.xxl),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.l),
                  child: Row(
                    children: [
                      const DenMark(size: 40),
                      const SizedBox(width: Sp.m),
                      Semantics(header: true, child: Text('Set up Den', style: context.type.heading(c.ink))),
                    ],
                  ),
                ),
                Divider(color: c.rule),
                if (steps) ...[
                  HomeScreenSteps(ipad: web.ipad),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Sp.s, Sp.xl, Sp.l, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() => _inSafari = true),
                        child: const Text('Use Den in Safari instead'),
                      ),
                    ),
                  ),
                ] else ...[
                  if (canStart)
                    _ChoiceRow(
                      icon: PhosphorIconsRegular.houseLine,
                      label: 'Start a family',
                      onTap: () => context.go('/welcome/start'),
                    ),
                  if (canJoin)
                    _ChoiceRow(
                      icon: _browser ? PhosphorIconsRegular.chatCircleText : PhosphorIconsRegular.qrCode,
                      label: 'Join your family',
                      onTap: () => context.go('/welcome/join'),
                    ),
                  if (_browser && !web.ios && hub != null && hub.paired)
                    _ChoiceRow(
                      icon: PhosphorIconsRegular.browser,
                      label: "Link with a parent's phone",
                      onTap: () => context.go('/welcome/link'),
                    ),
                  _ChoiceRow(
                    icon: PhosphorIconsRegular.usersThree,
                    label: 'Look around with a demo family',
                    busy: _startingDemo,
                    onTap: _startingDemo ? null : _demo,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.icon, required this.label, required this.onTap, this.busy = false});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.rule)),
      ),
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 80),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.l),
            child: Row(
              children: [
                Icon(icon, size: 28, color: c.ink),
                const SizedBox(width: Sp.l),
                Expanded(child: Text(label, style: context.type.title(c.ink))),
                if (busy)
                  SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: c.ink2))
                else
                  Icon(PhosphorIconsRegular.caretRight, size: 20, color: c.ink2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
