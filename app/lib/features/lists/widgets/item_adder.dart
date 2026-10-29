import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';

/// The one add field for a list ("2 milk @Costco, eggs", read by `parseItems`) and the round
/// Add. On a shopping list, where new things go sits in the field as a chip ("Costco ▾",
/// "Any store ▾"); tapping it opens a short picker under the row: Any store, the family's
/// stores, and New store… with a field for its name. The choice stays for the next things
/// added, and the keyboard stays up through all of it.
class AddItemRow extends StatefulWidget {
  const AddItemRow({
    super.key,
    required this.hint,
    required this.onAdd,
    this.enabled = true,
    this.autofocus = false,
    this.stores,
    this.store,
    this.onStore,
  });

  final String hint;
  final Future<bool> Function(String text) onAdd;
  final bool enabled;
  final bool autofocus;

  /// The stores to offer, most used first; null shows no chip (lists that aren't shopping).
  final List<String>? stores;

  /// Where new things go; null is any store.
  final String? store;
  final ValueChanged<String?>? onStore;

  @override
  State<AddItemRow> createState() => _AddItemRowState();
}

class _AddItemRowState extends State<AddItemRow> {
  final _focus = FocusNode();
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  bool _picking = false;
  bool _naming = false;

  @override
  void dispose() {
    _focus.dispose();
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _toggle() => setState(() {
        _picking = !_picking;
        _naming = false;
      });

  /// Picks [store] and hands the keyboard back to the add field for the next thing.
  void _choose(String? store) {
    widget.onStore?.call(store);
    setState(() {
      _picking = false;
      _naming = false;
    });
    _name.clear();
    _focus.requestFocus();
  }

  void _newStore() {
    setState(() => _naming = true);
    _nameFocus.requestFocus();
  }

  void _useName() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _nameFocus.requestFocus();
      return;
    }
    // A store the family already uses keeps its own spelling.
    final known = (widget.stores ?? const <String>[]).where((s) => s.toLowerCase() == name.toLowerCase()).firstOrNull;
    _choose(known ?? name);
  }

  @override
  Widget build(BuildContext context) {
    final stores = widget.stores;
    final store = widget.store;
    final options = stores == null ? const <String>[] : [if (store != null && !stores.contains(store)) store, ...stores];
    return InlineAdd(
      hint: widget.hint,
      onAdd: widget.onAdd,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      focusNode: _focus,
      trailing: stores == null ? null : StoreChip(store: store, open: _picking, onTap: widget.enabled ? _toggle : null),
      below: stores == null
          ? null
          : DenReveal(
              visible: _picking,
              child: Padding(
                padding: const EdgeInsets.only(top: Sp.s),
                child: GroupCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: ruled(
                      [
                        _StoreRow(label: 'Any store', chosen: store == null, onTap: () => _choose(null)),
                        for (final s in options) _StoreRow(label: s, chosen: s == store, onTap: () => _choose(s)),
                        DenCrossfade(
                          child: !_naming
                              ? _StoreRow(
                                  key: const ValueKey('new'),
                                  label: 'New store…',
                                  icon: PhosphorIconsBold.plus,
                                  chosen: false,
                                  onTap: _newStore,
                                )
                              : _NameRow(key: const ValueKey('name'), controller: _name, focusNode: _nameFocus, onDone: _useName),
                        ),
                      ],
                      indent: _StoreRow.textStart,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// A store in the picker: an ink check before the chosen one (a plus before New store…).
class _StoreRow extends StatelessWidget {
  const _StoreRow({super.key, required this.label, required this.chosen, required this.onTap, this.icon});

  /// Where the words start, for the rules between rows.
  static const double textStart = 22 + Sp.m;

  final String label;
  final bool chosen;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final glyph = icon ?? (chosen ? PhosphorIconsBold.check : null);
    return Semantics(
      inMutuallyExclusiveGroup: icon == null,
      checked: icon == null ? chosen : null,
      child: DenPressable(
        onTap: onTap,
        scale: false,
        shape: const RoundedRectangleBorder(),
        semanticLabel: label,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.s),
            child: Row(
              children: [
                SizedBox(width: 22, child: glyph == null ? null : Icon(glyph, size: 20, color: c.ink)),
                const SizedBox(width: Sp.m),
                Expanded(child: ExcludeSemantics(child: Text(label, style: chosen ? t.body(c.ink).bold : t.body(c.ink)))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// New store…, open: its name, and Add store. Return does the same.
class _NameRow extends StatelessWidget {
  const _NameRow({super.key, required this.controller, required this.focusNode, required this.onDone});

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.s),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              // Return picks it and hands the keyboard back to the add field.
              onEditingComplete: () {},
              onSubmitted: (_) => onDone(),
              style: context.text.body(c.ink),
              // On the card, the field takes the page's color so it shows.
              decoration: InputDecoration(hintText: 'Store name', fillColor: c.bg),
            ),
          ),
          const SizedBox(width: Sp.s),
          FilledButton(onPressed: onDone, child: const Text('Add store', maxLines: 1, softWrap: false)),
        ],
      ),
    );
  }
}

/// Where new things go, as a chip in the add field: the store's name (or "Any store") and a
/// caret that turns while its picker is open. 32 tall on the field's card, outlined; 44 to tap.
class StoreChip extends StatelessWidget {
  const StoreChip({super.key, required this.store, required this.open, required this.onTap});

  final String? store;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final fg = onTap == null ? c.ink3 : c.ink;
    final pill = DenPressable(
      onTap: onTap,
      color: c.card,
      shape: StadiumBorder(side: BorderSide(color: open ? c.ink : c.line, width: 1.5)),
      selected: open,
      semanticLabel: 'New items go to ${store ?? 'any store'}. Change store',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Sp.m, Sp.xs, Sp.s, Sp.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: ExcludeSemantics(child: Text(store ?? 'Any store', style: t.meta(fg).bold))),
              const SizedBox(width: Sp.xs),
              SpringValue(
                value: open ? 0.5 : 0,
                builder: (context, turns, _) => Transform.rotate(
                  angle: turns * 2 * math.pi,
                  child: Icon(PhosphorIconsBold.caretDown, size: MediaQuery.textScalerOf(context).scale(14), color: c.ink2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // The pill shows 32 tall; the 6 above and below still take the tap.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: pill),
    );
  }
}
