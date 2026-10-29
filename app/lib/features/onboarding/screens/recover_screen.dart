import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/pairing.dart';
import '../../../platform/web/web_app.dart';
import '../state/recovery_input.dart';
import '../state/this_device.dart';
import 'home_screen_steps.dart';

/// "I lost my phone": a parent whose phone is gone, with no other parent's device left to let a
/// new one in, types or pastes the 12 recovery words they saved, or the 4 words (or the link)
/// whoever runs the hub gave them. Den asks the family's hub whose they are and shows that
/// person; "Yes, let this phone in" makes this device theirs, at once. Nothing is written
/// before they say it's them.
class RecoverScreen extends StatefulWidget {
  const RecoverScreen({super.key, this.code, this.browser, this.web});

  /// The four words from the hub's link (`/#/recover/<w>-<w>-<w>-<w>`).
  final String? code;

  /// Recovers as a browser served by the hub, for tests; by default only on the web.
  final bool? browser;

  /// The browser, for tests; by default read from the page.
  final WebAppInfo? web;

  @override
  State<RecoverScreen> createState() => _RecoverScreenState();
}

class _RecoverScreenState extends State<RecoverScreen> {
  late final _words = TextEditingController(text: widget.code)..addListener(_typed);
  final _hub = TextEditingController();
  DeviceKind? _kind;
  RecoverySession? _session;
  bool _busy = false;
  bool _inSafari = false;
  String? _error;

  bool get _browser => widget.browser ?? Capabilities.web;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _kind ??= widget.web?.kind ?? guessDeviceKind(context);
  }

  @override
  void dispose() {
    _words.dispose();
    _hub.dispose();
    super.dispose();
  }

  void _typed() => setState(() => _error = null);

  /// This device's name once Den knows whose it is: "Alex's new iPhone".
  String _name(String person) {
    final base = suggestDeviceName(person, _kind ?? DeviceKind.phone);
    final apostrophe = base.indexOf("'s ");
    return apostrophe < 0 ? base : '${base.substring(0, apostrophe + 3)}new ${base.substring(apostrophe + 3)}';
  }

  Future<void> _find() async {
    final typed = readRecoveryInput(_words.text);
    final problem = switch (typed.kind) {
      RecoveryTyped.empty => 'Type or paste your 12 recovery words.',
      RecoveryTyped.partial => 'That\'s ${typed.count} of 12 words. Type all of them, in order.',
      RecoveryTyped.wrongWord => 'One of the words isn\'t right. Check them against where you saved them.',
      RecoveryTyped.twelve || RecoveryTyped.four => null,
    };
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final pairing = Pairing.of(context);
    try {
      final session = await pairing.startRecovery(
        _words.text,
        hubUrl: _hub.text.trim().isEmpty ? null : _hub.text.trim(),
        deviceName: _name,
        kind: _kind!,
      );
      if (mounted) setState(() => _session = session);
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final session = _session!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ticket = await session.confirm();
      Pairing.ticket = ticket;
      if (mounted) context.go('/welcome/waiting');
    } on PairingException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _notMe() async {
    final session = _session;
    setState(() {
      _session = null;
      _error = null;
    });
    await session?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final web = widget.web ?? WebApp.info;
    if (_browser && web.needsHomeScreen && !_inSafari) {
      final four = readRecoveryInput(widget.code ?? '').kind == RecoveryTyped.four;
      return DenPage(
        title: 'Get back in',
        children: [
          HomeScreenSteps(ipad: web.ipad, code: four ? widget.code!.replaceAll(RegExp(r'[-_]+'), ' ') : null),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => setState(() => _inSafari = true), child: const Text('Get back in here in Safari instead')),
          ),
        ],
      );
    }
    final session = _session;
    return session == null ? _enter(context) : _who(context, session);
  }

  Widget _enter(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final typed = readRecoveryInput(_words.text);
    final counter = typed.kind == RecoveryTyped.partial && typed.count > 0 ? '${typed.count} of 12 words' : null;
    return DenPage(
      title: 'Get back in',
      bottom: FilledButton(
        onPressed: _busy ? null : _find,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(_busy ? 'Checking the words' : 'Find me'),
      ),
      children: [
        Text(
          'Type or paste the 12 recovery words you saved when you set up Den. If whoever runs your hub gave you 4 '
          'words, those work too.',
          style: t.body(c.ink2),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledField(
              label: 'Your recovery words',
              error: _error,
              child: TextField(
                controller: _words,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.multiline,
                minLines: 3,
                maxLines: 6,
                style: t.body(c.ink),
                decoration: const InputDecoration(hintText: 'maple river canoe tiger ...'),
              ),
            ),
            if (counter != null && _error == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.s, DenLayout.headingInset, 0),
                child: Text(counter, style: t.meta(c.ink2)),
              ),
          ],
        ),
        if (!_browser)
          LabeledField(
            label: "Your hub's address, if this device can't find it",
            child: TextField(
              controller: _hub,
              autocorrect: false,
              keyboardType: TextInputType.url,
              style: t.body(c.ink),
              decoration: const InputDecoration(hintText: 'https://den.example.com'),
            ),
          ),
      ],
    );
  }

  Widget _who(BuildContext context, RecoverySession session) {
    final c = context.colors;
    final t = context.text;
    final name = session.memberName;
    final color = PersonColor.forMarker(session.marker ?? Marker.lavender).color;
    final picture = session.picture;
    final face = picture != null && picture != Picture.initial && Picture.pack.contains(picture)
        ? DenAvatar.picture(picture, color: color, size: 64, semanticLabel: name)
        : DenAvatar.initial(name, color: color, size: 64, semanticLabel: name);
    return DenPage(
      title: 'Is this you?',
      onBack: _busy ? null : _notMe,
      bottom: FilledButton(
        onPressed: _busy ? null : _confirm,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(_busy ? 'Letting this phone in' : 'Yes, let this phone in'),
      ),
      children: [
        GroupCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.l),
            child: Row(
              children: [
                face,
                const SizedBox(width: Sp.l),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: t.section(c.ink)),
                      if (session.familyName != null) Text(session.familyName!, style: t.meta(c.ink2)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Text(
          session.byHub
              ? 'This phone becomes $name\'s. Everyone in the family will see it was let in by the hub\'s recovery.'
              : 'This phone becomes $name\'s. Everyone in the family will see it was let in with $name\'s recovery words.',
          style: t.body(c.ink2),
        ),
        if (_error != null) ErrorState(message: _error!, actionLabel: 'Try again', onAction: _confirm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: _busy ? null : _notMe, child: const Text("That's not me")),
        ),
      ],
    );
  }
}
