import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../tokens.dart';
import 'buttons.dart';

/// Add one thing right where its list is: a field on the card color (14 corners, 52 tall) and a
/// round ink Add button. Return or the button adds; the field clears and keeps the keyboard up
/// for the next one. [onAdd] returns whether it worked (the words stay when it didn't).
class InlineAdd extends StatefulWidget {
  const InlineAdd({super.key, required this.hint, required this.onAdd, this.enabled = true});

  /// "Add to groceries": the field's placeholder and the button's label.
  final String hint;
  final Future<bool> Function(String text) onAdd;
  final bool enabled;

  @override
  State<InlineAdd> createState() => _InlineAddState();
}

class _InlineAddState extends State<InlineAdd> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
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
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _text,
            focusNode: _focus,
            enabled: widget.enabled,
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => _add(),
            style: context.text.body(c.ink),
            decoration: InputDecoration(hintText: widget.hint),
          ),
        ),
        const SizedBox(width: Sp.s),
        RoundButton(icon: PhosphorIconsBold.plus, label: widget.hint, onTap: widget.enabled ? _add : null),
      ],
    );
  }
}
