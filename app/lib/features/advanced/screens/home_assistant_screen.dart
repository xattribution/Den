import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';

/// Where the Home Assistant integration's README lives.
final Uri homeAssistantGuide = Uri.parse('https://github.com/xattribution/den/tree/main/integrations/homeassistant');

/// Advanced → Home Assistant: three steps, the hub's address, and a token made for it.
class HomeAssistantScreen extends StatefulWidget {
  const HomeAssistantScreen({super.key, this.hubAddress});

  /// The hub's address on the home network, once a hub is running.
  final String? hubAddress;

  @override
  State<HomeAssistantScreen> createState() => _HomeAssistantScreenState();
}

class _HomeAssistantScreenState extends State<HomeAssistantScreen> {
  String? _guideError;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.connection});
    final c = context.colors;
    final t = context.text;
    final hasToken = app.den.connections.any(
      (x) => x.status == ConnectionStatus.active && x.label.toLowerCase().contains('home assistant'),
    );
    final address = widget.hubAddress ?? app.network?.localHub.addresses.map((a) => '${a.host}:${a.port}').firstOrNull;
    return DenPage(
      title: 'Home Assistant',
      children: [
        DenSection(
          title: 'Connect it',
          child: const NumberedSteps(steps: [
            'In Home Assistant, install the Den integration from HACS.',
            'Add the Den integration. It finds the hub on your network, or you type the hub address below.',
            'Paste a token made for Home Assistant.',
          ]),
        ),
        DenSection(
          title: 'Hub address',
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.l),
            child: address != null
                ? SelectableText(address, style: t.rowTitle(c.ink))
                : Text("Home Assistant finds the family's hub on your network.", style: t.body(c.ink2)),
          ),
        ),
        DenSection(
          title: 'Token',
          child: EmptyState(
            compact: true,
            message: hasToken ? 'Home Assistant has a token.' : 'Home Assistant needs a token to sign in.',
            actionLabel: hasToken ? 'Make another token' : 'Make a token for Home Assistant',
            onAction: () => context.push('/settings/connections/new?label=Home%20Assistant'),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton.icon(
              onPressed: () async {
                final ok = await launchUrl(homeAssistantGuide, mode: LaunchMode.externalApplication);
                if (!ok && mounted) setState(() => _guideError = "Couldn't open the browser. The guide is at $homeAssistantGuide");
              },
              icon: const Icon(PhosphorIconsRegular.arrowSquareOut, size: 18),
              label: const Text('Read the integration guide'),
            ),
            if (_guideError != null) SelectableText(_guideError!, style: t.meta(c.destructive)),
          ],
        ),
      ],
    );
  }
}
