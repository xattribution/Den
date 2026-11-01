import 'dart:async';

import 'package:flutter/material.dart';

import 'passkeys.dart';

/// A button that opens the browser's passkey sheet (Face ID, a fingerprint, the screen lock).
///
/// Safari opens that sheet only inside the person's own tap, and Flutter's pointer pipeline
/// doesn't always keep the tap (web/den_web.js, "passkeys", says when). So over the button
/// Flutter draws lies a real, invisible `<button>` ([PasskeyBrowser.overlay], a platform view of
/// the same size), and its own click starts the sheet in the page, at once, with the options
/// [ready] says were armed before the tap. Flutter's button still shows the press and speaks to
/// screen readers. When the tap reaches Flutter's button without the page's click (a keyboard's
/// Enter, a screen reader's double tap, or a browser that didn't give the click to the
/// element), it starts the sheet itself, straight from its handler; the page runs one at a time.
///
/// Without [ready] (the challenge is still on its way) the button waits, disabled. [onResult]
/// gets what the sheet answered.
class PasskeyButton extends StatefulWidget {
  const PasskeyButton({
    super.key,
    required this.kind,
    required this.label,
    required this.ready,
    required this.onResult,
    this.busy = false,
    this.busyLabel,
    this.filled = true,
    this.icon,
    this.browser,
  });

  final PasskeyKind kind;
  final String label;

  /// The hub's options are armed in the page, so a tap can open the sheet at once.
  final bool ready;

  /// Something is under way after the sheet (the hub checking it): the button waits.
  final bool busy;

  /// What the button says while [busy], or while the sheet is up.
  final String? busyLabel;

  /// The ink pill (a page's one primary action); otherwise the outlined secondary button.
  final bool filled;

  final IconData? icon;

  final void Function(PasskeyOutcome outcome) onResult;

  /// The browser, for tests; [PasskeyBrowser.current] by default.
  final PasskeyBrowser? browser;

  @override
  State<PasskeyButton> createState() => _PasskeyButtonState();
}

class _PasskeyButtonState extends State<PasskeyButton> {
  /// How long a pointer's tap waits for the page's own click before starting the sheet itself.
  static const _clickWait = Duration(milliseconds: 500);

  bool _open = false;
  bool _pointer = false;
  Timer? _fallback;
  Widget? _overlay;

  PasskeyBrowser get _browser => widget.browser ?? PasskeyBrowser.current;

  @override
  void initState() {
    super.initState();
    _overlay = _browser.overlay(widget.kind, _started);
  }

  @override
  void dispose() {
    _fallback?.cancel();
    super.dispose();
  }

  bool get _enabled => widget.ready && !widget.busy && !_open;

  /// The page's click started the sheet (or, without the overlay, Flutter's handler did).
  void _started(Future<PasskeyOutcome> answer) {
    _fallback?.cancel();
    _fallback = null;
    if (_open || !mounted) return;
    setState(() => _open = true);
    answer.then((outcome) {
      if (!mounted) return;
      setState(() => _open = false);
      widget.onResult(outcome);
    });
  }

  void _pressed() {
    if (_overlay != null && _pointer) {
      // A finger or a mouse: the page's own click on the overlay starts the sheet. Should it not
      // come (a browser that kept the click from the element), start it from here instead.
      _pointer = false;
      _fallback?.cancel();
      _fallback = Timer(_clickWait, () {
        _fallback = null;
        if (mounted && !_open) _started(_browser.start(widget.kind));
      });
      return;
    }
    _pointer = false;
    // A keyboard or a screen reader: inside its own key or click event, so straight from here.
    _started(_browser.start(widget.kind));
  }

  @override
  Widget build(BuildContext context) {
    final waiting = widget.busy || _open;
    final text = Text(waiting ? widget.busyLabel ?? widget.label : widget.label, maxLines: 1, softWrap: false);
    final onPressed = _enabled ? _pressed : null;
    final Widget button = widget.filled
        ? (widget.icon == null
            ? FilledButton(
                onPressed: onPressed,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                child: text,
              )
            : FilledButton.icon(
                onPressed: onPressed,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                icon: Icon(widget.icon, size: 22),
                label: text,
              ))
        : (widget.icon == null
            ? OutlinedButton(onPressed: onPressed, child: text)
            : OutlinedButton.icon(onPressed: onPressed, icon: Icon(widget.icon, size: 20), label: text));
    final overlay = _overlay;
    return Listener(
      onPointerDown: (_) => _pointer = true,
      // Flutter's tap (and _pressed) comes in the same event, after this; a press that wasn't a
      // tap (a scroll) leaves nothing behind for a later key press.
      onPointerUp: (_) => scheduleMicrotask(() => _pointer = false),
      onPointerCancel: (_) => _pointer = false,
      child: overlay == null || !_enabled
          ? button
          : Stack(
              children: [
                button,
                // Flutter lets the press through to its own button below; the browser gives the
                // click to this element above it.
                Positioned.fill(child: IgnorePointer(child: ExcludeSemantics(child: overlay))),
              ],
            ),
    );
  }
}
