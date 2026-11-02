import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/widgets.dart';

/// Settings: how large this device draws text, on top of the system's own size. A Home Screen
/// web app never hears the iPhone's Text Size setting, so this is the way to larger words there;
/// elsewhere it adds to it. Either way text stops growing at 200 %.
///
/// A row on Settings that says the size now ("Text size, Default") and opens a short sheet: one
/// tap picks a size and closes it.
class TextSizeRow extends StatelessWidget {
  const TextSizeRow({super.key, this.icon});

  final IconData? icon;

  static const choices = [
    Choice(TextSize.standard, 'Default', detail: 'The size this device uses'),
    Choice(TextSize.larger, 'Larger'),
    Choice(TextSize.largest, 'Largest'),
  ];

  /// What [size] is called on the row and in the sheet.
  static String label(TextSize size) => choices.firstWhere((c) => c.value == size).label;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {Changes.prefs});
    return NavRow(
      icon: icon,
      label: 'Text size',
      value: label(app.textSize),
      onTap: () async {
        final size = await showChoiceSheet<TextSize>(context, title: 'Text size', choices: choices, value: app.textSize);
        if (size != null) app.textSize = size;
      },
    );
  }
}
