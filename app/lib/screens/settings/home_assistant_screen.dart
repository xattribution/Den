import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/parts/family_frame.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';

/// Where the Home Assistant integration's README lives.
final Uri homeAssistantGuide = Uri.parse('https://github.com/xattribution/den/tree/main/integrations/homeassistant');

/// Connecting Home Assistant: three steps, the hub's address, and a token made for it.
class HomeAssistantScreen extends StatelessWidget {
  const HomeAssistantScreen({super.key, this.hubAddress});

  /// The hub's address on the home network, once a hub is running.
  final String? hubAddress;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasToken = context.den.connections.any(
      (x) => x.status == ConnectionStatus.active && x.label.toLowerCase().contains('home assistant'),
    );
    final steps = [
      'In Home Assistant, install the Den integration from HACS.',
      'Add the Den integration. It finds the hub on your network, or you enter the hub address below.',
      'Paste a token made for Home Assistant with Read, Calendar, Chores and Lists.',
    ];
    return FormFrame(
      title: 'Home Assistant',
      children: [
        const SizedBox(height: Sp.s),
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.s),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: c.ink2, width: 1.5),
                  ),
                  child: Text('${i + 1}', style: context.type.bodyStrong(c.ink)),
                ),
                const SizedBox(width: Sp.m),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(steps[i], style: context.type.body(c.ink)),
                  ),
                ),
              ],
            ),
          ),
        const SectionHeader('Hub address'),
        if (hubAddress != null)
          FormBlock(top: 0, child: SelectableText(hubAddress!, style: context.type.title(c.ink)))
        else
          const FormBlock(
            top: 0,
            child: AttentionLine(message: 'No hub is running yet. Set one up first; its address shows here.'),
          ),
        const SectionHeader('Token'),
        FormBlock(
          top: 0,
          child: Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (hasToken) Text('Home Assistant has a token.', style: context.type.body(c.ink2)),
              OutlinedButton(
                onPressed: () => context.push('/settings/connections/new?label=Home%20Assistant'),
                child: Text(hasToken ? 'Create another token' : 'Create token for Home Assistant'),
              ),
            ],
          ),
        ),
        const SizedBox(height: Sp.l),
        FormBlock(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                final ok = await launchUrl(homeAssistantGuide, mode: LaunchMode.externalApplication);
                if (!ok && context.mounted) {
                  showNote(context, "Couldn't open the browser. The guide is at $homeAssistantGuide");
                }
              },
              icon: const Icon(PhosphorIconsRegular.arrowSquareOut, size: 18),
              label: const Text('Read the integration guide'),
            ),
          ),
        ),
      ],
    );
  }
}
