import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';

/// Settings, Appearance: how large this device draws text, on top of the system's own size. A
/// Home Screen web app never hears the iPhone's Text Size setting, so this is the way to larger
/// words there; elsewhere it adds to it. Either way text stops growing at 200 %.
class TextSizeChoice extends StatelessWidget {
  const TextSizeChoice({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {Changes.prefs});
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
          child: Semantics(header: true, child: Text('Text size', style: context.text.meta(c.ink2))),
        ),
        const SizedBox(height: Sp.s),
        GroupCard(
          child: ChoiceRows<TextSize>(
            choices: const [
              Choice(TextSize.standard, 'Default', detail: 'The size this device uses'),
              Choice(TextSize.larger, 'Larger'),
              Choice(TextSize.largest, 'Largest'),
            ],
            value: app.textSize,
            onChanged: (size) => app.textSize = size,
          ),
        ),
      ],
    );
  }
}
