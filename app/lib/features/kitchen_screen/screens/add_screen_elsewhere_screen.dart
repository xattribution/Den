import 'package:den_net/den_net.dart' show ScreenCode;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';

/// A kitchen screen's QR code opened where Den holds no family (`/welcome/add-screen?code=`):
/// the phone's camera opened it in Safari, say, while the family lives in the Home Screen app.
/// Says where to type the code instead, and shows it.
class AddScreenElsewhereScreen extends StatelessWidget {
  const AddScreenElsewhereScreen({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final shown = ScreenCode.normalize(code);
    return DenPage(
      title: 'Add a screen',
      children: [
        Text(
          'Open Den where your family is (on an iPhone, from the Home Screen), then go to Settings, Kitchen screen, '
          'Add a screen, and type this code:',
          style: t.body(c.ink),
        ),
        if (shown != null) Text(ScreenCode.format(shown), style: t.display(c.ink).copyWith(letterSpacing: 3)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: () => context.go('/welcome'), child: const Text('Set up Den on this device instead')),
        ),
      ],
    );
  }
}
