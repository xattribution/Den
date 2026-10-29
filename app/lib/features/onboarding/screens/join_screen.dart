import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show normalizeCode, spokenCodeWords;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/pairing.dart';
import '../../../platform/web/web_app.dart';
import '../state/this_device.dart';
import 'home_screen_steps.dart';

/// Joining a family from a parent's invite: the four words from an invite message (filled in
/// when the invite's link opened Den, or by Paste from the message itself), or a QR code on a
/// phone or tablet with a camera. This
/// device's name comes from whom the invite is for ("Zoe's iPhone"). The waiting screen takes
/// over once the request is sent.
///
/// In Safari on an iPhone or iPad, Den goes on the Home Screen first: the family will live in
/// the Home Screen app, which keeps its own storage.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, this.scan, this.code, this.browser, this.web});

  /// Forces the camera on or off, for tests; by default phones and tablets scan.
  final bool? scan;

  /// The invite's words, from its link.
  final String? code;

  /// Joins as a browser served by the hub, for tests; by default only on the web.
  final bool? browser;

  /// The browser, for tests; by default read from the page.
  final WebAppInfo? web;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  late final _words = TextEditingController(text: widget.code);
  final _hub = TextEditingController();
  DeviceKind? _kind;
  late bool _scanning = widget.code == null && (widget.scan ?? Capabilities.scanQr);
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

  /// This device's name, from whom the invite is for ("Sam's iPhone").
  String _name(String? forName) => suggestDeviceName(forName ?? '', _kind ?? DeviceKind.phone);

  Future<void> _join(Future<JoinTicket> Function(PairingService p) send) async {
    setState(() {
      _error = null;
      _busy = true;
    });
    final pairing = Pairing.of(context);
    try {
      final ticket = await send(pairing);
      Pairing.ticket = ticket;
      if (mounted) context.go('/welcome/waiting');
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on InvalidInput catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _scanned(BarcodeCapture capture) {
    if (_busy) return;
    final raw = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw == null) return;
    if (raw.startsWith('den://link')) {
      setState(() => _error = "That's a browser's link code. Scan it from a parent's phone instead.");
      return;
    }
    if (!raw.startsWith('den://join')) {
      setState(() => _error = "That code isn't a Den invite. Ask a parent for an invite.");
      return;
    }
    _join((p) => p.joinWithQr(raw, deviceName: _name(null), kind: _kind!));
  }

  /// Fills the words from what's on the clipboard: the words alone, the link, or the whole
  /// invite message. Called straight from the tap, so a browser lets it read the clipboard.
  Future<void> _paste() async {
    final pasted = await WebApp.paste();
    String? text = pasted.text;
    if (text == null) {
      try {
        text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      } on Object {
        text = null;
      }
    }
    if (!mounted) return;
    final invite = inviteFrom(text ?? '');
    if (invite.words.length != spokenCodeWords) {
      setState(() => _error = "There's no invite on the clipboard. Copy the whole invite message, then tap Paste again.");
      return;
    }
    final words = normalizeCode(invite.words.join(' ')) ?? invite.words.join(' ');
    setState(() {
      _error = null;
      _words.value = TextEditingValue(text: words, selection: TextSelection.collapsed(offset: words.length));
      if (invite.hub != null && !_browser) _hub.text = invite.hub!;
    });
  }

  void _sendWords() {
    final typed = inviteFrom(_words.text);
    if (typed.words.length != 4) {
      setState(() => _error = 'Type all four words from the invite.');
      return;
    }
    final words = typed.words.join(' ');
    final hub = typed.hub ?? (_hub.text.trim().isEmpty ? null : _hub.text.trim());
    final kind = _kind!;
    _join((p) async {
      if (_browser || hub != null) {
        try {
          return await p.joinWithInvite(words, hubUrl: hub, deviceName: _name, kind: kind);
        } on PairingException catch (e) {
          // Not an invite the hub holds: maybe words a parent's phone is showing right now.
          if (_browser || e.reason != PairingException.unknownCode) rethrow;
        }
      }
      return p.joinWithCode(words, hubUrl: hub, deviceName: _name(null), kind: kind);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final web = widget.web ?? WebApp.info;
    final steps = _browser && web.needsHomeScreen && !_inSafari;
    final width = MediaQuery.sizeOf(context).width;
    final camera = (width.clamp(0.0, 560.0) - 64).clamp(200.0, 420.0);

    if (steps) {
      return DenPage(
        title: 'Join your family',
        children: [
          HomeScreenSteps(ipad: web.ipad, code: inviteFrom(widget.code ?? '').words.join(' ').nullIfEmpty),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => setState(() => _inSafari = true), child: const Text('Join here in Safari instead')),
          ),
        ],
      );
    }
    return DenPage(
      title: 'Join your family',
      bottom: _scanning
          ? null
          : FilledButton(
              onPressed: _busy ? null : _sendWords,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: Text(_busy ? 'Joining' : 'Join the family'),
            ),
      children: [
        if (_scanning) ...[
          Text("Scan the code on a parent's phone.", style: t.body(c.ink)),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.tile),
              child: SizedBox.square(
                dimension: camera,
                child: MobileScanner(
                  onDetect: _scanned,
                  errorBuilder: (context, error) => ColoredBox(
                    color: c.card,
                    child: Padding(
                      padding: const EdgeInsets.all(Sp.l),
                      child: Center(
                        child: Text(
                          "Den can't use the camera. Allow camera access in this device's settings, or type the words instead.",
                          style: t.body(c.ink2),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_error != null) Text(_error!, style: t.meta(c.destructive)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() {
                _scanning = false;
                _error = null;
              }),
              child: const Text('Type the words instead'),
            ),
          ),
        ] else ...[
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LabeledField(
                label: 'The four words from your invite',
                error: _error,
                child: TextField(
                  controller: _words,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: t.body(c.ink),
                  decoration: const InputDecoration(hintText: 'maple river canoe tiger'),
                  onSubmitted: (_) => _sendWords(),
                ),
              ),
              const SizedBox(height: Sp.m),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _paste,
                  icon: const Icon(PhosphorIconsRegular.clipboardText, size: 20),
                  label: const Text('Paste the invite'),
                ),
              ),
            ],
          ),
          if (!_browser)
            LabeledField(
              label: "The start of the invite's link, if this device can't find the hub",
              child: TextField(
                controller: _hub,
                autocorrect: false,
                keyboardType: TextInputType.url,
                style: t.body(c.ink),
                decoration: const InputDecoration(hintText: 'https://den.example.com'),
              ),
            ),
          if (widget.scan ?? Capabilities.scanQr)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() {
                  _scanning = true;
                  _error = null;
                }),
                child: const Text('Scan a code instead'),
              ),
            ),
        ],
      ],
    );
  }
}

/// An invite as someone typed or pasted it: the four words, and the hub's address when it came
/// with the link (`https://den.example.com/#/join/maple-river-canoe-tiger`). Takes the words
/// typed with spaces, dashes or commas, the link alone, or the whole invite message: the words
/// in its link, or else the one part of it that is four words ("type: maple river canoe
/// tiger"), preferring words from Den's word list.
({List<String> words, String? hub}) inviteFrom(String text) {
  final whole = text.trim();
  List<String> split(String s) => s.toLowerCase().split(RegExp(r'[\s,.\-_]+')).where((w) => w.isNotEmpty).toList();

  final link = RegExp(r'(\S*)#/join/([^\s#?&]+)').firstMatch(whole);
  if (link != null) {
    final base = Uri.tryParse(link.group(1)!);
    final hub = base != null && base.host.isNotEmpty && (base.scheme == 'https' || base.scheme == 'http')
        ? Uri(scheme: base.scheme, host: base.host, port: base.port).toString()
        : null;
    String path;
    try {
      path = Uri.decodeComponent(link.group(2)!);
    } on ArgumentError {
      path = link.group(2)!;
    }
    final words = split(path.replaceAll(RegExp(r'[^A-Za-z\-_ ]+$'), ''));
    if (words.length == spokenCodeWords) return (words: words, hub: hub);
  }

  final typed = split(whole);
  if (typed.length <= spokenCodeWords) return (words: typed, hub: null);

  // The whole message without a working link: the part between punctuation that is four words.
  final parts = [
    for (final part in whole.split(RegExp(r'[:;!?\n]|\.(?=\s|$)')))
      if (split(part).length == spokenCodeWords) split(part),
  ];
  final known = parts.where((p) => normalizeCode(p.join(' ')) != null);
  if (known.isNotEmpty) return (words: known.last, hub: null);
  if (parts.isNotEmpty) return (words: parts.last, hub: null);
  return (words: typed, hub: null);
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
