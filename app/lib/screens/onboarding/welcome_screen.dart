import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/mark.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import 'demo_session.dart';

/// The first screen on a device with no family: the task, as three plain rows.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _startingDemo = false;

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
                _ChoiceRow(
                  icon: PhosphorIconsRegular.houseLine,
                  label: 'Start a family',
                  onTap: () => context.go('/welcome/start'),
                ),
                _ChoiceRow(
                  icon: PhosphorIconsRegular.qrCode,
                  label: 'Join your family',
                  onTap: () => context.go('/welcome/join'),
                ),
                _ChoiceRow(
                  icon: PhosphorIconsRegular.usersThree,
                  label: 'Look around with a demo family',
                  busy: _startingDemo,
                  onTap: _startingDemo ? null : _demo,
                ),
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
