import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show DenLink, DenLinkKind, normalizeCode, spokenCodeWords;
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

/// Joining a family from a parent's invite.
///
/// Opened from the invite's link (its words in [code]), it asks the hub what the words open and
/// says so ("Join the Riveras as Leo"), with one button: an invite that lets them in at once
/// does, and any other asks a parent. Without a link: the four words from the message (typed,
/// or by Paste from the message itself), or a QR code on a phone or tablet with a camera. This
/// device's name comes from whom the invite is for ("Zoe's iPhone").
///
/// In Safari on an iPhone or iPad, Den goes on the Home Screen first: the family will live in
/// the Home Screen app, which keeps its own storage and picks the invite up by itself.
///
/// With [another] it joins another family beside the one this device is in (`/families/join`):
/// its title says so, and getting back in on a new phone isn't offered there.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, this.scan, this.code, this.hub, this.another = false, this.browser, this.web});

  /// Forces the camera on or off, for tests; by default phones and tablets scan.
  final bool? scan;

  /// The invite's words, from its link.
  final String? code;

  /// The hub's address, when the invite's link carried it.
  final String? hub;

  /// Joining another family beside the one this device is in.
  final bool another;

  /// Joins as a browser served by the hub, for tests; by default only on the web.
  final bool? browser;

  /// The browser, for tests; by default read from the page.
  final WebAppInfo? web;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  late final _words = TextEditingController(text: widget.code);
  late final _hub = TextEditingController(text: widget.hub);
  DeviceKind? _kind;
  late bool _scanning = widget.code == null && (widget.scan ?? Capabilities.scanQr);
  bool _busy = false;
  bool _inSafari = false;
  String? _error;

  /// What the link's words open, once the hub said; null while asking, or typing words.
  InvitePeek? _peek;


  /// Typing words instead of joining with the link's.
  late bool _typing = widget.code == null;
  PairingService? _pairing;

  bool get _browser => widget.browser ?? Capabilities.web;

  WebAppInfo get _web => widget.web ?? WebApp.info;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _kind ??= widget.web?.kind ?? guessDeviceKind(context);
    final pairing = Pairing.of(context);
    if (pairing == _pairing) return;
    _pairing = pairing;
    final steps = _browser && _web.needsHomeScreen;
    if (!_typing && !steps) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _look();
      });
    }
  }

  @override
  void dispose() {
    _words.dispose();
    _hub.dispose();
    super.dispose();
  }

  /// What this device is, in a sentence: "iPhone", "iPad", "computer".
  String get _deviceWord {
    final web = _web;
    if (_browser && web.ios) return web.ipad ? 'iPad' : 'iPhone';
    return switch (_kind ?? DeviceKind.phone) {
      DeviceKind.phone => 'phone',
      DeviceKind.tablet => 'tablet',
      DeviceKind.desktop || DeviceKind.browser => 'computer',
      DeviceKind.hub => 'hub',
      DeviceKind.display => 'display',
    };
  }

  /// This device's name, from whom the invite is for ("Sam's iPhone").
  String _name(String? forName) => suggestDeviceName(forName ?? '', _kind ?? DeviceKind.phone);

  /// Asks the hub what the link's words open, for "Join the Riveras as Leo".
  Future<void> _look() async {
    setState(() => _error = null);
    try {
      final hub = _hub.text.trim();
      final peek = await _pairing!.peekInvite(_words.text, hubUrl: hub.isEmpty ? null : hub);
      if (mounted) setState(() => _peek = peek);
    } on PairingException catch (e) {
      if (mounted) {
        setState(() {
          _typing = true;
          _error = e.message;
        });
      }
    }
  }

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
    // An invite's link, shown as a QR code by "Open Den on your computer" or a parent's invite.
    final link = DenLink.parse(raw);
    if (link != null && link.kind == DenLinkKind.family && link.words != null) {
      setState(() {
        _scanning = false;
        _words.text = link.words!;
        if (link.hub != null && !_browser) _hub.text = link.hub.toString();
      });
      _sendWords();
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
      if (_browser || hub != null || widget.another) {
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
    final web = _web;
    if (_browser && web.needsHomeScreen && !_inSafari) {
      final link = widget.code == null ? null : DenLink.parse(widget.code!);
      return DenPage(
        title: _title,
        children: [
          HomeScreenSteps(ipad: web.ipad, link: link?.words == null ? null : DenLink(kind: DenLinkKind.family, words: link!.words)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                setState(() => _inSafari = true);
                if (!_typing) _look();
              },
              child: const Text('Join here in Safari instead'),
            ),
          ),
        ],
      );
    }
    if (!_typing) return _confirm(context, _peek);
    return _enter(context);
  }

  /// "Join the Riveras as Leo", from the link: one button.
  Widget _confirm(BuildContext context, InvitePeek? peek) {
    final c = context.colors;
    final t = context.text;
    final name = peek?.memberName;
    final family = peek?.familyName ?? 'your family';
    final device = _deviceWord;
    final color = PersonColor.forMarker(peek?.marker ?? Marker.lavender).color;
    final picture = peek?.picture;
    final face = name == null
        ? SizedBox.square(dimension: 64, child: Icon(PhosphorIconsRegular.usersThree, size: 36, color: c.ink))
        : picture != null && picture != Picture.initial && Picture.pack.contains(picture)
            ? DenAvatar.picture(picture, color: color, size: 64, semanticLabel: name)
            : DenAvatar.initial(name, color: color, size: 64, semanticLabel: name);
    return DenPage(
      title: _title,
      bottom: FilledButton(
        onPressed: _busy || peek == null ? null : _sendWords,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(_busy ? 'Joining' : name == null ? 'Join' : 'Join as $name'),
      ),
      children: [
        if (peek == null)
          NoticeLine(icon: PhosphorIconsRegular.hourglass, message: 'Finding your invite')
        else ...[
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
                        Text(name ?? family, style: t.section(c.ink)),
                        if (name != null) Text(family, style: t.meta(c.ink2)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Text(
            name == null
                ? (peek.letsIn ? 'This $device joins at once.' : 'A parent lets this $device in.')
                : (peek.letsIn ? "This $device becomes $name's, as soon as you tap Join." : "This $device becomes $name's once a parent lets it in."),
            style: t.body(c.ink2),
          ),
        ],
        if (_error != null) ErrorState(message: _error!, actionLabel: 'Try again', onAction: _sendWords),
        if (name != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _busy ? null : () => setState(() => _typing = true),
              child: Text("Not $name? Use other words"),
            ),
          ),
      ],
    );
  }

  Widget _enter(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final width = MediaQuery.sizeOf(context).width;
    final camera = (width.clamp(0.0, 560.0) - 64).clamp(200.0, 420.0);
    return DenPage(
      title: _title,
      bottom: _scanning
          ? null
          : FilledButton(
              onPressed: _busy ? null : _sendWords,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: Text(_busy ? 'Joining' : widget.another ? 'Join' : 'Join the family'),
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
        if (!widget.another)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => context.push('/welcome/recover'), child: const Text('I lost my phone')),
          ),
      ],
    );
  }

  String get _title => widget.another ? 'Join another family' : 'Join your family';
}

/// An invite as someone typed or pasted it: the four words, and the hub's address when it came
/// with the link (`https://den.example.com/#/join/maple-river-canoe-tiger`). Takes the words
/// typed with spaces, dashes or commas, the link alone, or the whole invite message
/// (den_net's [DenLink] reads them all).
({List<String> words, String? hub}) inviteFrom(String text) {
  final link = DenLink.parse(text);
  if (link == null || link.words == null) {
    final typed = text.toLowerCase().split(RegExp(r'[\s,.\-_]+')).where((w) => w.isNotEmpty).toList();
    return (words: typed, hub: null);
  }
  return (words: link.words!.split(' '), hub: link.hub?.toString());
}
