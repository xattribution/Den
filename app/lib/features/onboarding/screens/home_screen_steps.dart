import 'package:flutter/material.dart';

import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';

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
    final t = context.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DenSection(
          title: 'Add Den to your Home Screen',
          child: NumberedSteps(steps: [
            ipad ? 'Tap Share at the top of Safari.' : "Tap Share at the bottom of Safari. If you don't see it, tap the three dots first.",
            'Tap Add to Home Screen, then Add.',
            'Open Den from your Home Screen.',
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.m, DenLayout.headingInset, 0),
          child: Text(
            'From the Home Screen, Den opens like an app, works without a connection and can send reminders.',
            style: t.meta(c.ink2),
          ),
        ),
        if (code != null) ...[
          const SizedBox(height: DenLayout.sectionGap),
          DenSection(
            title: 'Then type this code',
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.l),
              child: SelectableText(code!, style: t.sheetTitle(c.ink).copyWith(fontSize: 24)),
            ),
          ),
        ],
      ],
    );
  }
}
