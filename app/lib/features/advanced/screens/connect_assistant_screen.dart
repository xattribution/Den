import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/den_network.dart';
import '../state/connection_actions.dart';
import '../widgets/scope_picker.dart';

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

/// An assistant or app a family connects, and how it gets in: by signing in (Den shows a code
/// and a parent lets it in) or with a token Den makes here.
enum Assistant {
  claude('Claude', signsIn: true),
  chatgpt('ChatGPT', signsIn: true),
  gemini('Gemini', signsIn: true),
  grok('Grok'),
  siri('Siri'),
  homeAssistant('Home Assistant'),
  alexa('Alexa+', signsIn: true),
  other('Something else');

  const Assistant(this.label, {this.signsIn = false});
  final String label;

  /// Signs in on its own: paste the address, then let it in when the code matches. The rest take
  /// a token.
  final bool signsIn;

  static Assistant? named(String? label) {
    final l = label?.toLowerCase().trim();
    if (l == null || l.isEmpty) return null;
    for (final a in values) {
      if (a.label.toLowerCase() == l) return a;
    }
    return other;
  }
}

/// Settings → AI and assistants → Connect an assistant: pick which one. One that signs in gets
/// Den's address and its steps; any other gets a token made right here, shown once beside the
/// address, with Copy for each and for both, and the steps for it.
class ConnectAssistantScreen extends StatefulWidget {
  const ConnectAssistantScreen({super.key, this.label, this.address, this.token});

  /// The assistant to start with, by name ("Home Assistant", "Siri"); anything else is a custom
  /// one named that.
  final String? label;

  /// Den's address for assistants, for tests; by default from the hub.
  final String? address;

  /// Shows the one-time token directly, for tests.
  final String? token;

  @override
  State<ConnectAssistantScreen> createState() => _ConnectAssistantScreenState();
}

class _ConnectAssistantScreenState extends State<ConnectAssistantScreen> {
  late Assistant? _pick = Assistant.named(widget.label);
  late final _name = TextEditingController(text: _pick == Assistant.other ? widget.label : '');
  Set<Scope> _scopes = {Scope.read, Scope.calendar, Scope.chores, Scope.lists};
  late String? _member = DenScope.read(context).me?.id;
  late String? _token = widget.token;
  late Future<String?> _address;
  bool _started = false;
  bool _options = false;
  bool _tried = false;
  bool _busy = false;
  String? _copied;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _address = widget.address != null ? Future.value(widget.address) : mcpAddress(context.watch(const {}).network);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _label => _pick == Assistant.other ? _name.text.trim() : (_pick?.label ?? '');

  Future<void> _connect() async {
    setState(() => _tried = true);
    final label = _label;
    final member = _member;
    if (label.isEmpty || _scopes.isEmpty || member == null) return;
    setState(() => _busy = true);
    final connections = context.connectionActions;
    String? token;
    await attempt(context, () async => token = await connections.addToken(label: label, scopes: _scopes, member: member));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _token = token;
    });
  }

  Future<void> _copy(String what, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(() => _copied = what);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.connection});
    final trusted = app.allowsTrust(DenAction.manageFamily);
    return FutureBuilder<String?>(
      future: _address,
      builder: (context, snap) {
        final asking = snap.connectionState != ConnectionState.done;
        final address = snap.data;
        final token = _token;
        if (token != null) return _made(context, token, address, asking);
        return _choose(context, address, asking, trusted);
      },
    );
  }

  /// Which assistant, then what it needs: the address for one that signs in, or Connect for one
  /// that takes a token.
  Widget _choose(BuildContext context, String? address, bool asking, bool trusted) {
    final c = context.colors;
    final t = context.text;
    final pick = _pick;
    final takesToken = pick != null && !pick.signsIn;
    return DenPage(
      title: 'Connect an assistant',
      bottom: takesToken
          ? FilledButton(
              onPressed: _busy || _scopes.isEmpty || !trusted ? null : _connect,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: Text(_label.isEmpty ? 'Connect' : 'Connect $_label', maxLines: 1, overflow: TextOverflow.ellipsis),
            )
          : null,
      children: [
        DenSection(
          title: 'Which one',
          child: ChoiceRows<Assistant?>(
            choices: [for (final a in Assistant.values) Choice(a, a.label)],
            value: pick,
            onChanged: (a) => setState(() {
              _pick = a;
              _tried = false;
            }),
          ),
        ),
        if (pick != null && pick.signsIn) ...[
          _AddressSection(address: address, asking: asking, copied: _copied == 'address', onCopy: (a) => _copy('address', a)),
          DenSection(title: 'In ${pick.label}', child: NumberedSteps(steps: _signInSteps(pick))),
        ],
        if (takesToken) ...[
          if (!trusted)
            const NoticeLine(
              icon: PhosphorIconsRegular.lockKey,
              message: "Assistants are connected only on a parent's own phone.",
            ),
          if (pick == Assistant.other)
            LabeledField(
              label: "What it's called",
              error: _tried && _name.text.trim().isEmpty ? 'Name it, like Dots or a script.' : null,
              child: TextField(
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                style: t.body(c.ink),
                decoration: const InputDecoration(hintText: 'Dots'),
                onChanged: (_) => setState(() {}),
              ),
            ),
          DenSection(
            title: 'What it can do',
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.m),
              child: Row(
                children: [
                  Expanded(child: Text(_summary(context), style: t.body(c.ink))),
                  TextButton(
                    onPressed: () => setState(() => _options = !_options),
                    child: Text(_options ? 'Done' : 'Change'),
                  ),
                ],
              ),
            ),
          ),
          if (_options) ...[
            ScopePicker(value: _scopes, onChanged: (s) => setState(() => _scopes = s)),
            ActsAsPicker(value: _member ?? '', onChanged: (m) => setState(() => _member = m)),
          ],
        ],
      ],
    );
  }

  /// "Sees and changes the calendar, chores and lists, as you."
  String _summary(BuildContext context) {
    final den = DenScope.read(context).den;
    final me = DenScope.read(context).me?.id;
    final who = _member == null || _member == me ? 'as you' : 'as ${den.member(_member!)?.name ?? 'someone'}';
    final does = [
      for (final s in Scope.values)
        if (_scopes.contains(s) && s != Scope.read) _scopeWord(s),
    ];
    final sees = _scopes.contains(Scope.read);
    if (does.isEmpty) return sees ? 'Sees what you see, $who. Changes nothing.' : 'Nothing yet.';
    final list = does.length == 1 ? does.first : '${does.take(does.length - 1).join(', ')} and ${does.last}';
    return '${sees ? 'Sees and changes' : 'Changes'} $list, $who.';
  }

  static String _scopeWord(Scope s) => switch (s) {
        Scope.read => 'what you see',
        Scope.calendar => 'the calendar',
        Scope.chores => 'chores',
        Scope.lists => 'lists',
        Scope.points => 'stars',
        Scope.admin => 'family settings',
      };

  /// The token, shown once, beside the address: Copy for each and Copy both, then the steps.
  Widget _made(BuildContext context, String token, String? address, bool asking) {
    final c = context.colors;
    final t = context.text;
    final label = _label.isEmpty ? (widget.label ?? 'it') : _label;
    final pick = _pick ?? Assistant.other;
    final both = [if (address != null) 'Address: $address', 'Token: $token'].join('\n');
    return DenPage(
      title: '$label is connected',
      back: false,
      bottom: FilledButton(
        onPressed: () => context.pop(),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: const Text('Done'),
      ),
      children: [
        const NoticeLine(
          icon: PhosphorIconsRegular.key,
          message: "Den shows this token only now. Copy it into the assistant before you leave this page.",
        ),
        if (pick != Assistant.siri && pick != Assistant.homeAssistant)
          _AddressSection(address: address, asking: asking, copied: _copied == 'address', onCopy: (a) => _copy('address', a)),
        DenSection(
          title: 'Token',
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.m),
            child: Row(
              children: [
                Expanded(child: SelectableText(token, style: t.rowTitle(c.ink).copyWith(letterSpacing: 0.5))),
                const SizedBox(width: Sp.s),
                OutlinedButton(onPressed: () => _copy('token', token), child: Text(_copied == 'token' ? 'Copied' : 'Copy')),
              ],
            ),
          ),
        ),
        if (address != null && pick != Assistant.siri && pick != Assistant.homeAssistant)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
              child: OutlinedButton.icon(
                onPressed: () => _copy('both', both),
                icon: Icon(_copied == 'both' ? PhosphorIconsBold.check : PhosphorIconsRegular.copy, size: 18),
                label: Text(_copied == 'both' ? 'Copied both' : 'Copy both'),
              ),
            ),
          ),
        DenSection(title: 'In $label', child: NumberedSteps(steps: _tokenSteps(context, pick, label, address))),
      ],
    );
  }

  static const _letIn = 'It shows a code. Back here in AI and assistants, let it in when the code matches, then '
      'choose what it may do and as whom.';

  List<Object> _signInSteps(Assistant a) => switch (a) {
        Assistant.claude => const [
            'In Claude (the website, desktop app or phone app), open Settings, then Connectors, and add a custom connector.',
            "Paste Den's address and add it.",
            _letIn,
          ],
        Assistant.chatgpt => const [
            "In ChatGPT's settings, turn on developer mode (Plus, Pro, Business, Enterprise or Edu), then add Den as an "
                "app with OAuth, using Den's address.",
            _letIn,
            'ChatGPT asks you before every change it makes.',
          ],
        Assistant.gemini => const [
            'On gemini.google.com, open Settings, then Connected Apps, then Add a custom app.',
            "Paste Den's address.",
            _letIn,
          ],
        Assistant.alexa => const [
            'Under Apps you set up, in AI and assistants, set up an app named Alexa with the redirect addresses the '
                'Alexa+ Developer Hub lists.',
            'Den shows its id and secret once: enter them where Alexa+ asks for account linking.',
            _letIn,
          ],
        _ => const [],
      };

  List<Object> _tokenSteps(BuildContext context, Assistant a, String label, String? address) {
    final c = context.colors;
    final t = context.text;
    final actions = address?.replaceFirst(RegExp(r'/mcp$'), '/api/v1/actions/add_from_text');
    return switch (a) {
      Assistant.grok => const [
          'On grok.com/connectors, choose New Connector, then Custom.',
          "Paste Den's address, and the token where it asks for a bearer token or API key.",
          'If Grok asks you to sign in instead, let it in here when the code matches.',
        ],
      Assistant.siri => [
          'In Shortcuts, make a Shortcut named "Add to Den": Dictate Text, then Get Contents of URL.',
          if (actions == null)
            "For the URL, use the hub's address with /api/v1/actions/add_from_text, Method POST, a header "
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
        ],
      Assistant.homeAssistant => const [
          'In Home Assistant, install the Den integration from HACS.',
          'Add the Den integration. It finds the hub on your network, or you type the hub address.',
          'Paste the token.',
        ],
      _ => [
          "In $label, add an MCP server (it may say connector or tool) with Den's address.",
          'Where it asks how to sign in, choose a bearer token or API key and paste the token.',
        ],
    };
  }
}

/// Den's address for assistants, with Copy; or why there is none yet.
class _AddressSection extends StatelessWidget {
  const _AddressSection({required this.address, required this.asking, required this.copied, required this.onCopy});

  final String? address;
  final bool asking;
  final bool copied;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final address = this.address;
    return DenSection(
      title: "Den's address",
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.m),
        child: asking
            ? Text('Asking the hub', style: t.body(c.ink2))
            : address == null
                ? Text(
                    'Assistants reach Den from the internet, so the hub needs a public https address. Whoever set '
                    "up the hub can give it one; it's in the hub's hosting guide.",
                    style: t.body(c.ink),
                  )
                : Row(
                    children: [
                      Expanded(child: SelectableText(address, style: t.rowTitle(c.ink))),
                      const SizedBox(width: Sp.s),
                      OutlinedButton(onPressed: () => onCopy(address), child: Text(copied ? 'Copied' : 'Copy')),
                    ],
                  ),
      ),
    );
  }
}
