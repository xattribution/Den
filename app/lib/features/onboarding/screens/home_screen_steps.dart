import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/forms/forms.dart';

/// Safari on an iPhone or iPad: put Den on the Home Screen first, in three steps. The Home
/// Screen app keeps its own storage, apart from Safari's, so a family started in Safari
/// wouldn't be there, and only the Home Screen app can show reminders.
class HomeScreenSteps extends StatelessWidget {
  const HomeScreenSteps({super.key, this.ipad = false, this.code});

  /// iPad Safari keeps Share at the top.
  final bool ipad;

  /// An invite's words, shown so they're at hand after the move.
  final String? code;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget step(int n, IconData icon, String text) => Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.l, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 28,
                child: Text('$n', style: context.type.title(c.ink)),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2, right: Sp.m),
                child: Icon(icon, size: 24, color: c.ink),
              ),
              Expanded(child: Text(text, style: context.type.body(c.ink))),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const InfoHeader(
          'Add Den to your Home Screen',
          info: 'From the Home Screen, Den opens like an app, works without a connection and can send '
              "reminders. It keeps its own storage there, separate from Safari's.",
        ),
        step(
          1,
          PhosphorIconsRegular.export,
          ipad
              ? 'Tap Share at the top of Safari.'
              : "Tap Share at the bottom of Safari. If you don't see it, tap the three dots first.",
        ),
        step(2, PhosphorIconsRegular.plusSquare, 'Tap Add to Home Screen, then Add.'),
        step(3, PhosphorIconsRegular.houseLine, 'Open Den from your Home Screen.'),
        if (code != null) ...[
          FormBlock(
            top: Sp.xl,
            child: Text('Then type this code when Den asks for it:', style: context.type.body(c.ink2)),
          ),
          FormBlock(
            top: Sp.xs,
            child: SelectableText(code!, style: context.type.heading(c.ink)),
          ),
        ],
      ],
    );
  }
}
