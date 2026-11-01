import 'dart:convert';

import 'package:den_core/den_core.dart' show DenAction, DeviceMode;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/hub_client.dart';
import '../../family/family.dart';
import '../state/sign_in_setup.dart';

export '../state/sign_in_setup.dart';

/// Where Google's console is.
final Uri googleConsole = Uri.parse('https://console.cloud.google.com/auth/clients');

/// Where Apple's identifiers and keys are.
final Uri appleAccount = Uri.parse('https://developer.apple.com/account/resources/identifiers/list');

/// A `.p8` file someone chose: its name, and what it holds.
typedef PickedKey = ({String name, String text});

/// Settings → Advanced → Sign in with Google or Apple, on a parent's own phone in the family
/// whose server it is: turns signing in with Google (and Apple) on for the hub, for every family
/// on the server. Step by step through Google's console, with the addresses to paste there and a
/// Copy button for each; then the client ID and secret go to the hub, which checks them with
/// Google and keeps them. The hub never shows them again: this screen says only On, with Change
/// and Turn off.
class SignInSetupScreen extends StatefulWidget {
  const SignInSetupScreen({super.key, this.source, this.pickKey, this.open});

  /// The hub's side; tests pass a fake.
  final SignInSetupSource? source;

  /// Picks the `.p8` file; tests pass their own.
  final Future<PickedKey?> Function()? pickKey;

  /// Opens a page in the browser; tests pass their own.
  final Future<bool> Function(Uri url)? open;

  @override
  State<SignInSetupScreen> createState() => _SignInSetupScreenState();
}

class _SignInSetupScreenState extends State<SignInSetupScreen> {
  SignInSetupSource? _source;
  bool _started = false;
  bool _loading = true;
  SignInSetupStatus? _status;
  String? _loadError;
  bool _notHost = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final network = context.watch(const {}).network;
    final hasHub = network != null && (network.isHub || network.hubDevice != null);
    _source = widget.source ?? (hasHub ? HubSignInSetupSource(network) : null);
    _load();
  }

  Future<void> _load() async {
    final source = _source;
    if (source == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final status = await source.status();
      if (mounted) setState(() => _status = status);
    } on HubException catch (e) {
      if (mounted) {
        setState(() {
          _notHost = e.code == 'host_family_only';
          _loadError = _notHost ? null : e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _show(SignInSetupStatus status) {
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final t = context.text;
    final own = app.allows(DenAction.manageFamily) && app.den.thisDevice?.mode == DeviceMode.personal;
    final status = _status;
    return DenPage(
      title: 'Sign in with Google or Apple',
      children: [
        Text(
          'Lets each parent sign in to Den in a browser with their Google or Apple account. You set it up once, '
          'here, for every family on your server.',
          style: t.body(c.ink2),
        ),
        if (!own)
          const NoticeLine(icon: PhosphorIconsRegular.lockKey, message: 'This is set up on a parent\'s own phone.')
        else if (_source == null)
          const NoticeLine(icon: PhosphorIconsRegular.info, message: 'This needs the family\'s hub. Add one under Hub and sync first.')
        else if (_loading && status == null)
          const NoticeLine(icon: PhosphorIconsRegular.hourglass, message: 'Asking the hub')
        else if (_notHost)
          const NoticeLine(
            icon: PhosphorIconsRegular.lockKey,
            message: 'Whoever runs your family\'s server sets this up, for every family on it. Once it\'s on, set up your own '
                'account under Settings, Google or Apple sign-in.',
          )
        else if (_loadError != null || status == null)
          GroupCard(child: ErrorState(message: _loadError ?? 'Couldn\'t reach the hub.', actionLabel: 'Try again', onAction: _load))
        else if (!status.https)
          const NoticeLine(
            icon: PhosphorIconsRegular.info,
            message: 'Signing in with Google or Apple needs your hub at an https address, where they send people back. '
                'Whoever set up the hub can give it one.',
          )
        else ...[
          _GoogleBlock(status: status, source: _source!, onChanged: _show, open: widget.open),
          _AppleBlock(status: status, source: _source!, onChanged: _show, open: widget.open, pickKey: widget.pickKey),
          if (status.withoutHttps.isNotEmpty)
            NoticeLine(
              icon: PhosphorIconsRegular.info,
              message: '${status.withoutHttps.join(', ')} ${status.withoutHttps.length == 1 ? 'has' : 'have'} no https '
                  'address, so ${status.withoutHttps.length == 1 ? 'that family' : 'those families'} can\'t sign in this way.',
            ),
        ],
      ],
    );
  }
}

/// "Turned on by Alex, Oct 3".
String _since(ProviderSetup p) {
  final when = p.setAt == null ? null : DateFormat('MMM d').format(p.setAt!);
  return switch ((p.setBy, when)) {
    (final by?, final at?) => 'Turned on by $by, $at',
    (final by?, null) => 'Turned on by $by',
    (null, final at?) => 'Turned on $at',
    _ => 'On for every family on your server',
  };
}

Future<bool> _launch(Future<bool> Function(Uri)? open, Uri url) =>
    (open ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank'))(url);

/// An address to paste somewhere else, with a Copy button.
class _CopyRow extends StatefulWidget {
  const _CopyRow(this.value);
  final String value;

  @override
  State<_CopyRow> createState() => _CopyRowState();
}

class _CopyRowState extends State<_CopyRow> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: const EdgeInsets.only(top: Sp.xs),
      child: Row(
        children: [
          Expanded(child: SelectableText(widget.value, style: t.body(c.ink).bold)),
          const SizedBox(width: Sp.s),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: widget.value));
              if (mounted) setState(() => _copied = true);
            },
            child: Text(_copied ? 'Copied' : 'Copy'),
          ),
        ],
      ),
    );
  }
}

/// Words, then addresses to copy: one step that holds more than words.
Widget _stepWith(BuildContext context, String words, List<String> values) {
  final c = context.colors;
  final t = context.text;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [Text(words, style: t.body(c.ink)), for (final v in values) _CopyRow(v)],
  );
}

/// A provider that is on: who turned it on, with Change and Turn off.
class _OnCard extends StatelessWidget {
  const _OnCard({
    required this.icon,
    required this.name,
    required this.setup,
    required this.busy,
    required this.confirmingOff,
    required this.error,
    required this.onChange,
    required this.onAskOff,
    required this.onOff,
    required this.onKeep,
  });

  final IconData icon;
  final String name;
  final ProviderSetup setup;
  final bool busy;
  final bool confirmingOff;
  final String? error;
  final VoidCallback onChange;
  final VoidCallback onAskOff;
  final VoidCallback onOff;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return GroupCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.m),
              child: Row(
                children: [
                  Icon(icon, size: 22, color: c.ink),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('On', style: t.rowTitle(c.ink)),
                        Text(_since(setup), style: t.meta(c.ink2)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (confirmingOff)
            ConfirmPanel(
              message: 'Parents can\'t sign in with $name until it\'s on again. Their accounts stay set up.',
              confirmLabel: 'Turn off',
              destructive: true,
              busy: busy,
              error: error,
              onConfirm: onOff,
              onCancel: onKeep,
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.s),
              child: Wrap(
                spacing: Sp.s,
                children: [
                  OutlinedButton(onPressed: busy ? null : onChange, child: const Text('Change')),
                  TextButton(
                    onPressed: busy ? null : onAskOff,
                    style: TextButton.styleFrom(foregroundColor: c.destructive),
                    child: const Text('Turn off'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _GoogleBlock extends StatefulWidget {
  const _GoogleBlock({required this.status, required this.source, required this.onChanged, this.open});
  final SignInSetupStatus status;
  final SignInSetupSource source;
  final void Function(SignInSetupStatus) onChanged;
  final Future<bool> Function(Uri url)? open;

  @override
  State<_GoogleBlock> createState() => _GoogleBlockState();
}

class _GoogleBlockState extends State<_GoogleBlock> {
  final _id = TextEditingController();
  final _secret = TextEditingController();
  bool _changing = false;
  bool _confirmingOff = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _turnOn() async {
    final id = _id.text.trim(), secret = _secret.text.trim();
    if (id.isEmpty || secret.isEmpty) {
      setState(() => _error = 'Paste both the client ID and the client secret.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await widget.source.turnOnGoogle(clientId: id, clientSecret: secret);
      _id.clear();
      _secret.clear();
      if (mounted) setState(() => _changing = false);
      widget.onChanged(status);
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOff() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await widget.source.turnOff('google');
      if (mounted) setState(() => _confirmingOff = false);
      widget.onChanged(status);
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final google = widget.status.google;
    final several = google.redirects.length > 1;
    if (google.on && !_changing) {
      return DenSection(
        title: 'Google',
        carded: false,
        child: _OnCard(
          icon: PhosphorIconsRegular.googleLogo,
          name: 'Google',
          setup: google,
          busy: _busy,
          confirmingOff: _confirmingOff,
          error: _error,
          onChange: () => setState(() => _changing = true),
          onAskOff: () => setState(() => _confirmingOff = true),
          onOff: _turnOff,
          onKeep: () => setState(() => _confirmingOff = false),
        ),
      );
    }
    return DenSection(
      title: 'Google',
      carded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GroupCard(
            child: NumberedSteps(steps: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('On a computer, open Google\'s console and make a project. Call it Den.', style: t.body(c.ink)),
                  TextButton.icon(
                    onPressed: () => _launch(widget.open, googleConsole),
                    icon: const Icon(PhosphorIconsRegular.arrowSquareOut, size: 18),
                    label: const Text('Open Google\'s console'),
                  ),
                ],
              ),
              'Open Google Auth Platform. Under Branding, give the app a name (Den) and your email. Under Audience, choose '
                  'External, then Publish app. Den asks only for each person\'s email, so Google doesn\'t need to review it.',
              'Under Clients, choose Create client, and pick Web application.',
              _stepWith(
                context,
                several
                    ? 'Under Authorized redirect URIs, add each of these, one for each family on your server:'
                    : 'Under Authorized redirect URIs, add this:',
                google.redirects,
              ),
              'Choose Create. Copy the Client ID and the Client secret into the boxes below.',
            ]),
          ),
          const SizedBox(height: Sp.l),
          LabeledField(
            label: 'Client ID',
            child: TextField(
              controller: _id,
              autocorrect: false,
              enableSuggestions: false,
              style: t.body(c.ink),
              decoration: const InputDecoration(hintText: '1234567890-abc.apps.googleusercontent.com'),
            ),
          ),
          const SizedBox(height: Sp.l),
          LabeledField(
            label: 'Client secret',
            error: _error,
            child: TextField(
              controller: _secret,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              style: t.body(c.ink),
              decoration: const InputDecoration(hintText: 'GOCSPX-...'),
              onSubmitted: (_) => _turnOn(),
            ),
          ),
          const SizedBox(height: Sp.l),
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              FilledButton(onPressed: _busy ? null : _turnOn, child: Text(_busy ? 'Checking with Google' : (google.on ? 'Save' : 'Turn on Google'))),
              if (_changing) TextButton(onPressed: _busy ? null : () => setState(() => _changing = false), child: const Text('Cancel')),
            ],
          ),
        ],
      ),
    );
  }
}

class _AppleBlock extends StatefulWidget {
  const _AppleBlock({required this.status, required this.source, required this.onChanged, this.open, this.pickKey});
  final SignInSetupStatus status;
  final SignInSetupSource source;
  final void Function(SignInSetupStatus) onChanged;
  final Future<bool> Function(Uri url)? open;
  final Future<PickedKey?> Function()? pickKey;

  @override
  State<_AppleBlock> createState() => _AppleBlockState();
}

class _AppleBlockState extends State<_AppleBlock> {
  final _services = TextEditingController();
  final _team = TextEditingController();
  final _keyId = TextEditingController();
  final _pasted = TextEditingController();
  PickedKey? _picked;
  bool _open = false;
  bool _confirmingOff = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _services.dispose();
    _team.dispose();
    _keyId.dispose();
    _pasted.dispose();
    super.dispose();
  }

  Future<PickedKey?> _pick() async {
    final pick = widget.pickKey;
    if (pick != null) return pick();
    // No type filter: a phone doesn't know what a .p8 is, and would grey it out.
    final file = await openFile();
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    if (bytes.length > 16 * 1024) return (name: file.name, text: '');
    return (name: file.name, text: utf8.decode(bytes, allowMalformed: true));
  }

  Future<void> _choose() async {
    try {
      final picked = await _pick();
      if (picked == null || !mounted) return;
      setState(() {
        if (!picked.text.contains('PRIVATE KEY')) {
          _error = '${picked.name} isn\'t a .p8 key. Choose the file Apple gave you, named like AuthKey_ABCDE12345.p8.';
          _picked = null;
        } else {
          _picked = picked;
          _error = null;
          final id = RegExp(r'AuthKey_([A-Z0-9]{10})\.p8$').firstMatch(picked.name)?.group(1);
          if (id != null && _keyId.text.trim().isEmpty) _keyId.text = id;
        }
      });
    } on Object {
      if (mounted) setState(() => _error = 'Couldn\'t open that file. Paste what it holds instead.');
    }
  }

  Future<void> _turnOn() async {
    final key = _picked?.text ?? _pasted.text.trim();
    final fields = [_services.text.trim(), _team.text.trim(), _keyId.text.trim()];
    if (fields.any((f) => f.isEmpty) || key.isEmpty) {
      setState(() => _error = 'Fill in the Services ID, Team ID and Key ID, and choose the .p8 file.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await widget.source.turnOnApple(servicesId: fields[0], teamId: fields[1], keyId: fields[2], key: key);
      for (final c in [_services, _team, _keyId, _pasted]) {
        c.clear();
      }
      if (mounted) {
        setState(() {
          _picked = null;
          _open = false;
        });
      }
      widget.onChanged(status);
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOff() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await widget.source.turnOff('apple');
      if (mounted) setState(() => _confirmingOff = false);
      widget.onChanged(status);
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final apple = widget.status.apple;
    if (apple.on && !_open) {
      return DenSection(
        title: 'Apple',
        carded: false,
        child: _OnCard(
          icon: PhosphorIconsRegular.appleLogo,
          name: 'Apple',
          setup: apple,
          busy: _busy,
          confirmingOff: _confirmingOff,
          error: _error,
          onChange: () => setState(() => _open = true),
          onAskOff: () => setState(() => _confirmingOff = true),
          onOff: _turnOff,
          onKeep: () => setState(() => _confirmingOff = false),
        ),
      );
    }
    if (!_open) {
      return DenSection(
        title: 'Apple',
        carded: false,
        child: GroupCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Needs a paid Apple Developer membership. Google works without it.', style: t.body(c.ink2)),
                const SizedBox(height: Sp.s),
                OutlinedButton(onPressed: () => setState(() => _open = true), child: const Text('Set up Apple')),
              ],
            ),
          ),
        ),
      );
    }
    final picked = _picked;
    return DenSection(
      title: 'Apple',
      carded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GroupCard(
            child: NumberedSteps(steps: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('On a computer, open Certificates, Identifiers & Profiles in your Apple Developer account.', style: t.body(c.ink)),
                  TextButton.icon(
                    onPressed: () => _launch(widget.open, appleAccount),
                    icon: const Icon(PhosphorIconsRegular.arrowSquareOut, size: 18),
                    label: const Text('Open Apple\'s page'),
                  ),
                ],
              ),
              'Under Identifiers, add an App ID with Sign in with Apple turned on.',
              _stepWith(context, 'Add a Services ID too, like family.den.signin. Turn on Sign in with Apple, choose Configure, pick the App '
                  'ID, and under Domains and Subdomains add:', apple.domains),
              _stepWith(context, 'Under Return URLs add:', apple.redirects),
              'Under Keys, add a key with Sign in with Apple, for the App ID. Download it: Apple gives the .p8 file only once. '
                  'Your Team ID is at the top right of the page.',
            ]),
          ),
          const SizedBox(height: Sp.l),
          LabeledField(
            label: 'Services ID',
            child: TextField(
              controller: _services,
              autocorrect: false,
              enableSuggestions: false,
              style: t.body(c.ink),
              decoration: const InputDecoration(hintText: 'family.den.signin'),
            ),
          ),
          const SizedBox(height: Sp.l),
          LabeledField(
            label: 'Team ID',
            child: TextField(
              controller: _team,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              style: t.body(c.ink),
              decoration: const InputDecoration(hintText: 'ABCDE12345'),
            ),
          ),
          const SizedBox(height: Sp.l),
          LabeledField(
            label: 'Key ID',
            child: TextField(
              controller: _keyId,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              style: t.body(c.ink),
              decoration: const InputDecoration(hintText: 'XYZ987ABCD'),
            ),
          ),
          const SizedBox(height: Sp.l),
          LabeledField(
            label: 'The key',
            error: _error,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _choose,
                      icon: const Icon(PhosphorIconsRegular.fileArrowUp, size: 20),
                      label: Text(picked == null ? 'Choose the .p8 file' : 'Choose another'),
                    ),
                    if (picked != null) ...[
                      const SizedBox(width: Sp.s),
                      Expanded(child: Text(picked.name, style: t.body(c.ink), overflow: TextOverflow.ellipsis)),
                    ],
                  ],
                ),
                if (picked == null) ...[
                  const SizedBox(height: Sp.s),
                  TextField(
                    controller: _pasted,
                    minLines: 2,
                    maxLines: 6,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: t.body(c.ink),
                    decoration: const InputDecoration(hintText: 'Or paste what it holds: -----BEGIN PRIVATE KEY-----...'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Sp.l),
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              FilledButton(onPressed: _busy ? null : _turnOn, child: Text(_busy ? 'Checking with Apple' : (apple.on ? 'Save' : 'Turn on Apple'))),
              TextButton(onPressed: _busy ? null : () => setState(() => _open = false), child: const Text('Cancel')),
            ],
          ),
        ],
      ),
    );
  }
}
