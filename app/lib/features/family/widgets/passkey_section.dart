import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/hub_client.dart';
import '../../../platform/sync/pairing.dart';
import '../../../platform/web/passkey_button.dart';
import '../../../platform/web/passkeys.dart';
import '../../../platform/web/web_app.dart';
import '../state/passkeys.dart';
import '../state/trust_actions.dart';
import 'family_parts.dart';

/// Whether this device can make [me] a passkey: a browser that can (a secure page at a host
/// name), the person's own personal device, a hub to keep it. Plain `http` on the home network
/// can't, and Den says nothing about it.
bool canMakePasskey(AppState app, {PasskeyBrowser? browser}) {
  final device = app.den.thisDevice;
  final me = app.me;
  return (browser ?? PasskeyBrowser.current).available &&
      me != null &&
      device != null &&
      device.approved &&
      device.mode == DeviceMode.personal &&
      device.member == me.id &&
      PasskeyHub.reachable(app);
}

/// Making a passkey on this device: the hub's options fetched (and fetched again before their
/// challenge runs out) and armed in the page, so the tap opens the browser's sheet at once; then
/// the browser's answer handed to the hub.
///
/// A parent's passkey lets them straight back in only while the family lets the hub help ("Let
/// the hub help us get back in"), so making one on a parent's own device turns that on too, as
/// the offer says. Anyone else's lets their new device ask, and a parent lets it in.
class PasskeyMaker extends ChangeNotifier {
  PasskeyMaker({required this.source, required this.browser});

  final PasskeySource source;
  final PasskeyBrowser browser;

  /// The options are armed: a tap opens the sheet.
  bool ready = false;

  /// The hub is checking the passkey (or the hub's help is being turned on).
  bool busy = false;

  /// This device can't make one after all (an older hub, another address): show nothing.
  bool unavailable = false;

  /// The passkey is made (or this device had one already).
  bool done = false;

  /// This device (or the passwords it syncs) had one of theirs already.
  bool already = false;

  /// What went wrong, for people.
  String? error;

  /// How many the person had before, on any device.
  int existing = 0;

  Timer? _refresh;
  bool _disposed = false;

  /// Fetches the options and arms them. Call it once, and again after each try (a challenge
  /// works once).
  Future<void> prepare() async {
    _refresh?.cancel();
    if (ready) {
      ready = false;
      _notify();
    }
    final PasskeyOptions options;
    try {
      options = await source.creationOptions();
    } on HubException catch (e) {
      if (e.code == 'not_found' || e.code == 'needs_https' || e.code == 'permission_denied') {
        unavailable = true;
      } else {
        error = e.message;
      }
      _notify();
      return;
    }
    if (_disposed) return;
    existing = options.existing;
    // The page must be at the address the hub names: a passkey belongs to it.
    if (options.rpId != browser.host || !browser.arm(PasskeyKind.create, options.options)) {
      unavailable = true;
      _notify();
      return;
    }
    ready = true;
    _notify();
    final left = options.expires - DateTime.now().millisecondsSinceEpoch - 30000;
    _refresh = Timer(Duration(milliseconds: left.clamp(10000, 600000)), prepare);
  }

  /// What the sheet answered: hands a new passkey to the hub, then [after] (turning the hub's
  /// help on for a parent); null from [after] when it worked, else why not.
  Future<void> answered(PasskeyOutcome outcome, {Future<String?> Function()? after}) async {
    error = null;
    switch (outcome) {
      case PasskeyRefused(alreadyHere: true):
        done = true;
        already = true;
        _notify();
        return;
      case PasskeyRefused(cancelled: true):
        // Closed, or it timed out: nothing to say, and a fresh challenge for the next tap.
        unawaited(prepare());
        return;
      case PasskeyRefused():
        error = "That didn't work. Try again.";
        unawaited(prepare());
        return;
      case PasskeyAnswer(:final credential):
        busy = true;
        _notify();
        try {
          await source.register(credential);
        } on HubException catch (e) {
          busy = false;
          error = e.message;
          _notify();
          unawaited(prepare());
          return;
        }
        final problem = await after?.call();
        busy = false;
        done = true;
        error = problem;
        _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _refresh?.cancel();
    super.dispose();
  }
}

/// For [me], a parent, on their own device: turns on "Let the hub help us get back in" so their
/// passkey lets them straight back in. Null when it's on (or isn't theirs to turn on), else why
/// not.
Future<String?> letHubHelpWithPasskey(BuildContext context, AppState app) async {
  final family = app.den.family;
  final me = app.me;
  if (family == null || me == null || !me.isParent || serverRecoveryKeyOf(family) != null) return null;
  if (!app.allowsTrust(DenAction.manageFamily)) return null;
  final pairing = Pairing.of(context);
  final trust = context.trustActions;
  try {
    final key = await pairing.hubRecoveryKey();
    return await tryWrite(() => trust.setHubHelp(key));
  } on PairingException catch (e) {
    return e.message;
  }
}

/// On the person's own page, on their own device: "Getting back in": their passkeys (Face ID on
/// an iPhone), each with Remove, and the button that makes one here. Shown only where this
/// browser can make one.
class PasskeySection extends StatefulWidget {
  const PasskeySection({super.key, required this.member, this.source, this.browser, this.web});

  /// The person whose page this is: the one using this device.
  final Member member;

  /// The hub, for tests; by default this device's.
  final PasskeySource? source;

  /// The browser, for tests.
  final PasskeyBrowser? browser;
  final WebAppInfo? web;

  @override
  State<PasskeySection> createState() => _PasskeySectionState();
}

class _PasskeySectionState extends State<PasskeySection> {
  PasskeyMaker? _maker;
  PasskeySource? _source;
  List<PasskeySummary>? _mine;
  String? _removing;
  bool _busy = false;
  String? _error;
  String? _done;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_source != null) return;
    final app = DenScope.read(context);
    final source = _source = widget.source ?? (PasskeyHub.reachable(app) ? PasskeyHub.source(app) : null);
    if (source == null) return;
    final maker = _maker = PasskeyMaker(source: source, browser: widget.browser ?? PasskeyBrowser.current)..addListener(_changed);
    maker.prepare();
    _load();
  }

  @override
  void dispose() {
    _maker?.dispose();
    super.dispose();
  }

  void _changed() {
    final maker = _maker;
    if (!mounted || maker == null) return;
    setState(() {});
    if (maker.done && !maker.busy) {
      _done = maker.error != null
          ? null
          : maker.already
              ? 'This ${_deviceWord(widget.web ?? (widget.browser ?? PasskeyBrowser.current).info)} has your passkey already.'
              : _words.done;
      maker.already = false;
      _error = maker.error;
      maker.done = false;
      _load();
      maker.prepare();
    }
  }

  PasskeyWords get _words => PasskeyWords.of(widget.web ?? (widget.browser ?? PasskeyBrowser.current).info);

  Future<void> _load() async {
    try {
      final mine = await _source!.mine();
      if (mounted) setState(() => _mine = mine);
    } on HubException {
      if (mounted) setState(() => _mine ??= const []);
    }
  }

  Future<void> _remove(PasskeySummary p) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? problem;
    try {
      await _source!.remove(p.id);
    } on HubException catch (e) {
      problem = e.message;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
      if (problem == null) {
        _removing = null;
        _done = 'Removed. It no longer gets you back in.';
        _mine = [for (final x in _mine ?? const <PasskeySummary>[]) if (x.id != p.id) x];
      }
    });
  }

  Future<void> _answered(PasskeyOutcome outcome) async {
    final app = DenScope.read(context);
    setState(() {
      _done = null;
      _error = null;
    });
    await _maker!.answered(outcome, after: () => letHubHelpWithPasskey(context, app));
  }

  @override
  Widget build(BuildContext context) {
    final maker = _maker;
    if (maker == null || (maker.unavailable && (_mine?.isEmpty ?? true))) return const SizedBox.shrink();
    final c = context.colors;
    final t = context.text;
    final words = _words;
    final mine = _mine ?? const <PasskeySummary>[];
    final app = context.watch(const {});
    final rows = <Widget>[];
    for (final p in mine) {
      final removing = _removing == p.id;
      final when = p.made == null ? null : DateFormat.yMMMd().format(DateTime.fromMillisecondsSinceEpoch(p.made!));
      rows.add(Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.m),
            child: Row(
              children: [
                Icon(PhosphorIconsRegular.fingerprint, size: 22, color: c.ink),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(words.setUp, style: t.rowTitle(c.ink)),
                      const SizedBox(height: 2),
                      Text(
                        [if (p.madeOn != null) 'Made on ${p.madeOn}', ?when].join(', '),
                        style: t.meta(c.ink2),
                      ),
                    ],
                  ),
                ),
                if (!removing)
                  TextButton(
                    onPressed: _busy ? null : () => setState(() => _removing = p.id),
                    style: TextButton.styleFrom(foregroundColor: c.destructive),
                    child: const Text('Remove', maxLines: 1, softWrap: false),
                  ),
              ],
            ),
          ),
          DenReveal(
            visible: removing,
            child: !removing
                ? const SizedBox(width: double.infinity)
                : ConfirmPanel(
                    message: "It stops getting you back in. Your phone may keep it until you delete it in Passwords.",
                    confirmLabel: 'Remove',
                    destructive: true,
                    busy: _busy,
                    error: _error,
                    onConfirm: () => _remove(p),
                    onCancel: () => setState(() {
                      _removing = null;
                      _error = null;
                    }),
                  ),
          ),
        ],
      ));
    }
    if (!maker.unavailable) {
      final device = _deviceWord(widget.web ?? (widget.browser ?? PasskeyBrowser.current).info);
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (mine.isEmpty) ...[
              Text(
                (app.me?.isParent ?? false)
                    ? 'If this $device is reset or Den is cleared, ${words.what} lets you straight back in. The hub '
                        "checks it, and the family can see when it's used."
                    : "If this $device is reset or Den is cleared, ${words.what} tells your family it's you, and a "
                        'parent lets you back in with one tap.',
                style: t.meta(c.ink2),
              ),
              const SizedBox(height: Sp.m),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: PasskeyButton(
                kind: PasskeyKind.create,
                label: mine.isEmpty ? words.make : 'Set up on this ${_deviceWord(widget.web ?? (widget.browser ?? PasskeyBrowser.current).info)} too',
                busyLabel: 'Setting it up',
                ready: maker.ready,
                busy: maker.busy,
                filled: false,
                icon: PhosphorIconsRegular.fingerprint,
                browser: widget.browser,
                onResult: _answered,
              ),
            ),
          ],
        ),
      ));
    }
    final problem = _error ?? maker.error;
    if (_done != null || problem != null) {
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: Sp.m),
        child: _done != null
            ? NoticeLine(icon: PhosphorIconsRegular.check, message: _done!)
            : Text(problem!, style: t.meta(c.destructive)),
      ));
    }
    return DenSection(
      title: 'Getting back in',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: ruled(rows, indent: 0)),
    );
  }
}

/// "iPhone", "iPad", "phone", "computer", for the sentences.
String _deviceWord(WebAppInfo web) => web.ios ? (web.ipad ? 'iPad' : 'iPhone') : web.android ? 'phone' : 'device';
