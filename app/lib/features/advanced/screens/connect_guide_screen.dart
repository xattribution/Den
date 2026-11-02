import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/den_network.dart';

/// The address assistants reach Den at: the hub's public https address and `/mcp`, or null when
/// Den knows none. A browser the hub served is at that address already.
Future<String?> mcpAddress(DenNetwork? network) async {
  final page = Uri.base;
  if (Capabilities.web && page.scheme == 'https') {
    return Uri(scheme: 'https', host: page.host, port: page.hasPort ? page.port : null, path: '/mcp').toString();
  }
  if (network == null) return null;
  final bases = await network.hubBases();
  for (final b in bases) {
    if (b.scheme == 'https') return b.replace(path: '/mcp').toString();
  }
  return null;
}

/// Advanced → AI and automations → Connect an assistant: Den's address for assistants, then
/// short steps for each one the family might use. Every one that signs in shows a code; a
/// parent lets it in here when the codes match and chooses what it may do.
class ConnectGuideScreen extends StatefulWidget {
  const ConnectGuideScreen({super.key, this.address});

  /// Den's address for assistants, for tests; by default from the hub.
  final String? address;

  @override
  State<ConnectGuideScreen> createState() => _ConnectGuideScreenState();
}

class _ConnectGuideScreenState extends State<ConnectGuideScreen> {
  late Future<String?> _address;
  bool _started = false;
  bool _copied = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _address = widget.address != null ? Future.value(widget.address) : mcpAddress(context.watch(const {}).network);
  }

  static const _signIn = 'A sign-in page opens with a code. Back here in AI and automations, let it in when the code '
      'matches, then choose what it may do and as whom.';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    Widget platform(String name, String who, List<Object> steps) => DenSection(
          title: name,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (who.isNotEmpty) Padding(padding: const EdgeInsets.only(top: Sp.m), child: Text(who, style: t.meta(c.ink2))),
              NumberedSteps(steps: steps),
            ],
          ),
        );
    return FutureBuilder<String?>(
      future: _address,
      builder: (context, snap) {
        final address = snap.data;
        // Siri's Shortcut runs on the phone, so the hub's own address works there too.
        final actions = address?.replaceFirst(RegExp(r'/mcp$'), '/api/v1/actions/add_from_text');
        return _page(context, platform, snap, address, actions);
      },
    );
  }

  Widget _page(
    BuildContext context,
    Widget Function(String name, String who, List<Object> steps) platform,
    AsyncSnapshot<String?> snap,
    String? address,
    String? actions,
  ) {
    final c = context.colors;
    final t = context.text;
    return DenPage(
      title: 'Connect an assistant',
      children: [
        Builder(
          builder: (context) {
            return DenSection(
              title: "Den's address",
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Sp.m),
                child: snap.connectionState != ConnectionState.done
                    ? Text('Asking the hub', style: t.body(c.ink2))
                    : address == null
                        ? Text(
                            "Assistants reach Den from the internet, so the hub needs a public https address. Whoever set "
                            "up the hub can give it one; it's in the hub's hosting guide.",
                            style: t.body(c.ink),
                          )
                        : Row(
                            children: [
                              Expanded(child: SelectableText(address, style: t.rowTitle(c.ink))),
                              const SizedBox(width: Sp.s),
                              OutlinedButton(
                                onPressed: () async {
                                  await Clipboard.setData(ClipboardData(text: address));
                                  if (mounted) setState(() => _copied = true);
                                },
                                child: Text(_copied ? 'Copied' : 'Copy'),
                              ),
                            ],
                          ),
              ),
            );
          },
        ),
        platform('Claude', 'On claude.ai, the desktop app or the phone app', const [
          'In Claude, open Settings, then Connectors, and add a custom connector.',
          "Paste Den's address and add it.",
          _signIn,
        ]),
        platform('ChatGPT', 'Plus, Pro, Business, Enterprise or Edu, with developer mode on', const [
          "In ChatGPT's settings, turn on developer mode, then add Den as an app with OAuth, using Den's address.",
          _signIn,
          'ChatGPT asks you before every change it makes.',
        ]),
        platform('Gemini', 'For a personal Google Account in the US, 18 or over, in English', const [
          'On gemini.google.com, open Settings, then Connected Apps, then Add a custom app.',
          "Paste Den's address.",
          _signIn,
        ]),
        platform('Grok', 'Needs the hub on the public internet', const [
          'On grok.com/connectors, choose New Connector, then Custom.',
          "Paste Den's address, then sign in.",
          _signIn,
        ]),
        platform('Siri', 'With a Shortcut on your iPhone; it works through your home connection too', [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Make a token for Siri that acts as you, and copy it.', style: t.body(c.ink)),
              const SizedBox(height: Sp.s),
              OutlinedButton(
                onPressed: () => context.push('/settings/connections/new?label=Siri'),
                child: const Text('Make a token for Siri'),
              ),
            ],
          ),
          'In Shortcuts, make a Shortcut named "Add to Den": Dictate Text, then Get Contents of URL.',
          if (actions == null)
            'For the URL, use the hub\'s address with /api/v1/actions/add_from_text, Method POST, a header '
                'Authorization: Bearer and the token, and a JSON body with text set to the Dictated Text.'
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('For the URL, use this, with Method POST:', style: t.body(c.ink)),
                SelectableText(actions, style: t.body(c.ink).bold),
                Text(
                  'Add a header Authorization: Bearer and the token, and a JSON body with text set to the Dictated Text.',
                  style: t.body(c.ink),
                ),
              ],
            ),
          'Add Get Dictionary Value text, then Speak Text, so Siri reads back what Den added.',
          'Say "Hey Siri, Add to Den", then "milk and eggs" or "soccer every Wednesday at 5 for Leo".',
        ]),
        platform('Alexa+', 'With the Alexa+ MCP toolkit, in preview', const [
          'Under Apps you set up in AI and automations, set up an app named Alexa with the redirect addresses the '
              'Alexa+ Developer Hub lists.',
          'Den shows its id and secret once: enter them where Alexa+ asks for account linking.',
          _signIn,
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
          child: Text(
            'Removing an assistant in AI and automations ends its access at once.',
            style: t.meta(c.ink2),
          ),
        ),
      ],
    );
  }
}
