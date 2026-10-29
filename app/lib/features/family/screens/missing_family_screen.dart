import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';

/// `/families/missing`: a link or a reminder named a family this device doesn't hold (it left,
/// or never joined), or one whose engine didn't open this time ([closed]). Said plainly, rather
/// than showing the page in whichever family the device shows.
class MissingFamilyScreen extends StatelessWidget {
  const MissingFamilyScreen({super.key, this.closed = false});

  /// The family is on this device, but Den couldn't open it just now.
  final bool closed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return DenPage(
      title: closed ? "That family didn't open" : "That family isn't on this device",
      bottom: FilledButton(
        onPressed: () => context.go('/today'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: const Text('Go to Today'),
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Icon(closed ? PhosphorIconsRegular.lockSimple : PhosphorIconsRegular.usersThree, size: 40, color: c.ink2),
        ),
        Text(
          closed
              ? "Den couldn't open that family on this device just now. Its calendar, chores and lists are still here. "
                  'Try again in a moment, or restart Den.'
              : 'That link or reminder is for a family this device left, or never joined. '
                  'Your families are in the switcher at the top of Today.',
          style: t.body(c.ink2),
        ),
      ],
    );
  }
}
