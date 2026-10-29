import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../tokens.dart';
import 'buttons.dart';

/// Add one thing right where its list is: a field on the card color (14 corners, 52 tall) and a
/// round ink Add button. Return or the button adds; the field clears and keeps the keyboard up
/// for the next one. [onAdd] returns whether it worked (the words stay when it didn't).
///
/// [trailing] sits at the end of the field (where the thing goes: "Costco ▾"), or under it once
/// the text is past 135 %, so it never squeezes what's typed; [below] opens under the row (a
/// short picker). Taps on either, and on the Add button, leave the keyboard up.
class InlineAdd extends StatefulWidget {
  const InlineAdd({
    super.key,
    required this.hint,
    required this.onAdd,
    this.enabled = true,
    this.autofocus = false,
    this.focusNode,
    this.trailing,
    this.below,
  });

  /// "Add to groceries": the field's placeholder and the button's label.
  final String hint;
  final Future<bool> Function(String text) onAdd;
  final bool enabled;

  /// Focuses the field when it first shows (a page opened to add something).
  final bool autofocus;

  /// The field's focus, for a picker that hands it back; by default its own.
  final FocusNode? focusNode;
  final Widget? trailing;
  final Widget? below;

  @override
  State<InlineAdd> createState() => _InlineAddState();
}

class _InlineAddState extends State<InlineAdd> {
  final _text = TextEditingController();
  FocusNode? _ownFocus;
  bool _busy = false;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void dispose() {
    _text.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _text.text.trim();
    if (text.isEmpty || _busy) {
      _focus.requestFocus();
      return;
    }
    setState(() => _busy = true);
    final ok = await widget.onAdd(text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) _text.clear();
    // Still focused (Return doesn't let go of it, nor does the Add button), so on a phone the
    // keyboard never went down; this only matters when the button was tapped from outside.
    if (!_focus.hasFocus) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final trailing = widget.trailing;
    final inside = trailing != null && MediaQuery.textScalerOf(context).scale(10) <= 13.5;
    final row = Row(
      children: [
        Expanded(
          child: TextField(
            controller: _text,
            focusNode: _focus,
            enabled: widget.enabled,
            autofocus: widget.autofocus,
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.sentences,
            // Return adds and keeps the field (and the keyboard): without this, "done" would let
            // go of the field first, and a field focused again after the add, outside the key
            // press, gets no keyboard in Safari.
            onEditingComplete: () {},
            onSubmitted: (_) => _add(),
            style: context.text.body(c.ink),
            decoration: InputDecoration(
              hintText: widget.hint,
              suffixIcon: inside ? Padding(padding: const EdgeInsetsDirectional.only(end: Sp.xs), child: trailing) : null,
              suffixIconConstraints: const BoxConstraints(minHeight: Targets.adult),
            ),
          ),
        ),
        const SizedBox(width: Sp.s),
        RoundButton(icon: PhosphorIconsBold.plus, label: widget.hint, onTap: widget.enabled ? _add : null),
      ],
    );
    // Taps anywhere here count as taps on the field, so they don't close the keyboard.
    return TextFieldTapRegion(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row,
          if (trailing != null && !inside)
            Padding(
              padding: const EdgeInsets.only(top: Sp.xs),
              child: Align(alignment: AlignmentDirectional.centerStart, child: trailing),
            ),
          ?widget.below,
        ],
      ),
    );
  }
}
