import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/forms/forms.dart' show Hang;
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../linked/linked_families.dart' show linkedFamilyName;
import '../state/list_actions.dart';
import '../state/lists_model.dart';
import '../words/list_words.dart';
import 'item_adder.dart';

/// One list's content (Lists.dc.html): when it's needed by, the one add field ("2 milk
/// @Costco, eggs") with where new things go, and the items (on a shopping list grouped by store,
/// with store chips to show one). Checking is one tap and happens in place: the item stays where
/// it is, crossed off, until "Clear checked" ([ClearChecked], floating over the page) takes the
/// checked ones away. Nothing moves while the list is open. Adding, removing and "Add to
/// groceries" each say what they did in place, with Undo.
class ListContent extends StatefulWidget {
  const ListContent({super.key, required this.list, this.focusAdd = false});

  final ListState list;

  /// Opens with the add field focused (Add's "Grocery item").
  final bool focusAdd;

  @override
  State<ListContent> createState() => _ListContentState();
}

class _ListContentState extends State<ListContent> {
  /// The store chip showing: null shows every store; the empty string the items with none.
  String? _store;

  /// Where new things go (a shopping list's add chip); null is any store. It follows the store
  /// chip showing, and stays as picked for the next things added.
  String? _addTo;
  Done? _added;

  /// The stores in the order their groups first showed, so checking, adding or clearing never
  /// moves a group while the list is open.
  final _storeOrder = <String>[];

  /// Items removed here, by id, with where they were so the note stays in their place.
  final _removed = <String, (Item, Done)>{};

  /// Meal items just put on the groceries, with their Undo.
  final _sent = <String, Done>{};

  @override
  void didUpdateWidget(ListContent old) {
    super.didUpdateWidget(old);
    if (old.list.list.id != widget.list.list.id) {
      _store = null;
      _addTo = null;
      _added = null;
      _storeOrder.clear();
      _removed.clear();
      _sent.clear();
    }
  }

  /// Shows one store (or all of them), and new things go there too.
  void _show(String? store) => setState(() {
        _store = store;
        _addTo = store == null || store.isEmpty ? null : store;
      });

  Future<void> _undo(Done note, VoidCallback forget) async {
    final receipt = note.receipt;
    if (receipt == null) return;
    final result = await perform(context, () => context.actions.undo(receipt));
    if (result != null && mounted) setState(forget);
  }

  Future<bool> _add(String text) async {
    final lv = widget.list;
    final shopping = lv.list.kind == ListKind.shopping;
    final read = parseItems(text, knownStores: DenScope.read(context).den.stores);
    if (read.isEmpty) return false;
    final to = shopping ? _addTo : null;
    final items = [for (final i in read) (text: i.text, qty: i.qty, store: i.store ?? to)];
    final result = await perform(context, () => context.listActions.addItems(lv.list.id, items));
    if (result == null || !mounted) return false;
    // "@Costco" moves the chip, so the next things go there too.
    final typed = read.lastWhere((i) => i.store != null, orElse: () => read.last).store;
    final stores = {for (final i in items) i.store};
    final at = shopping && stores.length == 1 && stores.single != null ? ' at ${stores.single}' : '';
    // What's already on the list isn't added twice; its quantity says how many.
    NewItem named(Object? i) => (text: '${(i as Map)['text']}', qty: null, store: null);
    final already = [for (final i in result.data['already'] as List? ?? const []) named(i)];
    final added = [for (final i in result.data['items'] as List? ?? const []) named(i)];
    final message = [
      if (added.isNotEmpty || already.isEmpty) 'Added ${itemNames(added.isEmpty ? read : added)}$at',
      if (already.isNotEmpty) '${itemNames(already)} ${already.length == 1 ? 'is' : 'are'} already on the list',
    ].join('. ');
    setState(() {
      if (shopping && typed != null) _addTo = typed;
      _added = (message: message, receipt: result.receipt);
    });
    return true;
  }

  Future<void> _remove(Item item) async {
    final result = await perform(context, () => context.listActions.remove(item));
    if (result == null || !mounted) return;
    setState(() => _removed[item.id] = (item, (message: 'Removed ${item.text}', receipt: result.receipt)));
  }

  Future<void> _toGroceries(Item item) async {
    if (groceriesList(DenScope.read(context).den) == null) {
      showNote(context, 'There\'s no shopping list to add to yet. Make one in Lists, then try again.');
      return;
    }
    final result = await perform(context, () => context.listActions.sendToGroceries(item));
    if (result == null || !mounted) return;
    setState(() => _sent[item.id] = (message: 'On the groceries', receipt: result.receipt));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(listReads);
    final c = context.colors;
    final t = context.text;
    final lv = app.den.list(widget.list.list.id) ?? widget.list;
    final kind = lv.list.kind;
    final shopping = kind == ListKind.shopping;
    // Another family's list they share only to see: theirs to change.
    final seeOnly = app.den.seeOnlyList(lv.list);
    final canEdit = app.canChangeItems && !seeOnly;
    final canCheck = app.allows(DenAction.checkItems) && !seeOnly;

    // Every item where it is, checked or not; removed ones keep their place for their note.
    final shown = [
      ...lv.items,
      for (final r in _removed.values)
        if (!lv.items.any((i) => i.id == r.$1.id)) r.$1,
    ]..sort((a, b) => a.order.compareTo(b.order));

    // Groups keep the order they first showed in (the family's most used stores first).
    final present = {for (final i in shown) if ((i.store ?? '').isNotEmpty) i.store!};
    if (present.any((s) => !_storeOrder.contains(s))) {
      final used = app.den.stores;
      final fresh = present.where((s) => !_storeOrder.contains(s)).toList()
        ..sort((a, b) {
          final ia = used.indexOf(a), ib = used.indexOf(b);
          if (ia != ib) return (ia < 0 ? 999 : ia).compareTo(ib < 0 ? 999 : ib);
          return a.compareTo(b);
        });
      _storeOrder.addAll(fresh);
    }
    final stores = [for (final s in _storeOrder) if (present.contains(s)) s];
    final noStore = shown.any((i) => (i.store ?? '').isEmpty);
    if (_store != null && _store!.isNotEmpty && !stores.contains(_store)) _store = null;
    if (_store == '' && !noStore) _store = null;
    final byStore = shopping && stores.isNotEmpty;

    Widget row(Item item) {
      final removed = _removed[item.id];
      if (removed != null) {
        return KeyedSubtree(
          key: ValueKey('removed:${item.id}'),
          child: DoneRow(
            message: removed.$2.message,
            onUndo: removed.$2.receipt?.undoable == true ? () => _undo(removed.$2, () => _removed.remove(item.id)) : null,
          ),
        );
      }
      return _ItemRow(
        key: ValueKey(item.id),
        item: item,
        kind: kind,
        canCheck: canCheck,
        onRemove: canEdit ? () => _remove(item) : null,
        onEdit: canEdit ? () => _editItem(item) : null,
        sent: _sent[item.id],
        onSend: kind == ListKind.meal && canEdit && !item.toGroceries ? () => _toGroceries(item) : null,
        onUndoSend: _sent[item.id]?.receipt?.undoable == true
            ? () => _undo(_sent[item.id]!, () => _sent.remove(item.id))
            : null,
      );
    }

    final groups = <String, List<Item>>{};
    if (byStore) {
      for (final s in [...stores, '']) {
        if (_store != null && _store != s) continue;
        final inStore = [for (final i in shown) if ((i.store ?? '') == s) i];
        if (inStore.isNotEmpty) groups[s] = inStore;
      }
    } else {
      groups[''] = shown;
    }

    final children = <Widget>[];

    if (lv.list.link case final link?) {
      final from = app.den.familyLink(link)?.name ?? '';
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: Sp.m),
        child: NoticeLine(
          icon: PhosphorIconsRegular.usersThree,
          message: '${linkedFamilyName(from)}\'s list${seeOnly ? ', to see' : ', shared with you'}',
        ),
      ));
    }
    if (listTiming(app, lv) case final timing?) {
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: Sp.m),
        child: NoticeLine(
          icon: timing.late ? PhosphorIconsBold.clockCountdown : PhosphorIconsRegular.calendarBlank,
          message: timing.text,
        ),
      ));
    }

    if (!seeOnly) {
      children.add(DisabledReason(
      disabled: !canEdit,
      reason: '${app.me?.name ?? 'You'} can check things off here, but adding needs the lists permission. A parent can turn it on in Family.',
      child: AddItemRow(
        hint: switch (kind) {
          // Short enough to read beside the store chip.
          ListKind.shopping => 'Add milk, eggs',
          ListKind.packing => 'Add sunscreen, 2 towels',
          ListKind.meal => 'Add a meal, like Tacos',
          ListKind.checklist => 'Add something to do',
        },
        enabled: canEdit,
        autofocus: widget.focusAdd,
        onAdd: _add,
        stores: shopping ? [..._storeOrder, for (final s in app.den.stores) if (!_storeOrder.contains(s)) s] : null,
        store: _addTo,
        onStore: (store) => setState(() => _addTo = store),
      ),
    ));
    }
    final added = _added;
    children.add(DenReveal(
      visible: added != null,
      child: added == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
              child: DoneRow(
                message: added.message,
                onUndo: added.receipt?.undoable == true ? () => _undo(added, () => _added = null) : null,
              ),
            ),
    ));

    if (byStore && (stores.length > 1 || (stores.isNotEmpty && noStore))) {
      // How many are still to get at each store.
      String label(String name, String s) {
        final n = lv.items.where((i) => !i.checked && (i.store ?? '') == s).length;
        return n == 0 ? name : '$name $n';
      }

      children.add(Padding(
        padding: const EdgeInsets.only(top: Sp.l),
        child: ChipRow(
          inset: 0,
          children: [
            TagChip(label: 'All stores', selected: _store == null, onTap: () => _show(null)),
            for (final s in stores)
              TagChip(label: label(s, s), selected: _store == s, onTap: () => _show(_store == s ? null : s)),
            if (noStore)
              TagChip(label: label('Anywhere', ''), selected: _store == '', onTap: () => _show(_store == '' ? null : '')),
          ],
        ),
      ));
    }

    if (lv.items.isEmpty && _removed.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: DenLayout.sectionGap),
        child: GroupCard(
          child: EmptyState(compact: true, message: 'Nothing on ${lv.list.title} yet.'),
        ),
      ));
    }

    for (final e in groups.entries) {
      if (e.value.isEmpty) continue;
      children.add(Padding(
        padding: const EdgeInsets.only(top: DenLayout.sectionGap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (byStore) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
                child: Semantics(
                  header: true,
                  child: Text(e.key.isEmpty ? 'Anywhere' : e.key, style: t.label(c.ink2)),
                ),
              ),
              const SizedBox(height: DenLayout.headingGap),
            ],
            GroupCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: ruled(e.value.map(row), indent: 42))),
          ],
        ),
      ));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Future<void> _editItem(Item item) => showDenSheet<void>(
        context,
        builder: (_) => _ItemSheet(item: item, kind: widget.list.list.kind, onRemove: () => _remove(item)),
      );
}

/// One item: a 28 pt ring, the words, and the quantity at the end; done is a filled ring,
/// words crossed off in ink, and who checked it, in the same place. A tap checks it (and a tap
/// in the same place takes it back); a long press (or a screen reader's action) edits it, and a
/// swipe removes it. On a meal plan, "Add to groceries" at the end.
class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.item,
    required this.kind,
    required this.canCheck,
    required this.onRemove,
    required this.onEdit,
    required this.sent,
    required this.onSend,
    required this.onUndoSend,
  });

  final Item item;
  final ListKind kind;
  final bool canCheck;
  final VoidCallback? onRemove;
  final VoidCallback? onEdit;
  final Done? sent;
  final VoidCallback? onSend;
  final VoidCallback? onUndoSend;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final checked = item.checked;
    final qty = item.qty ?? '';
    final by = checked ? DenScope.read(context).memberById(item.checkedBy)?.name : null;
    final trailing = checked ? (by ?? '') : qty;
    final meal = kind == ListKind.meal && !checked;

    Widget end;
    if (kind == ListKind.meal && (item.toGroceries || sent != null)) {
      end = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(PhosphorIconsBold.check, size: 16, color: c.ink2),
          const SizedBox(width: Sp.xs),
          Text('On groceries', style: t.meta(c.ink2)),
          if (onUndoSend != null) UndoButton(onTap: onUndoSend),
        ],
      );
    } else if (onSend != null && !checked) {
      end = TextButton(onPressed: onSend, child: const Text('Add to groceries', maxLines: 1, softWrap: false));
    } else {
      end = trailing.isEmpty ? const SizedBox.shrink() : Text(trailing, style: t.meta(c.ink2));
    }

    final row = Semantics(
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Edit item'): ?onEdit,
        const CustomSemanticsAction(label: 'Remove item'): ?onRemove,
      },
      child: DenPressable(
        onTap: canCheck ? () => attempt(context, () => context.listActions.setChecked(item, !checked)) : null,
        onLongPress: onEdit,
        scale: false,
        haptic: true,
        toggled: checked,
        semanticLabel: qty.isEmpty ? item.text : '${item.text}, $qty',
        shape: const RoundedRectangleBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              // Lists are nobody's color: a quiet ink ring, filled when done (Lists.dc.html), on
              // the check spring like every check.
              CheckRing(color: c.ink2, done: checked, size: 28, checkColor: c.card),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.s),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExcludeSemantics(
                        child: Text(
                          tidy(item.text),
                          // Crossed off in ink, the way a pen crosses off a paper list.
                          style: t.body(checked ? c.ink2 : c.ink).copyWith(
                                decoration: checked ? TextDecoration.lineThrough : null,
                                decorationColor: c.ink,
                                decorationThickness: 1.5,
                              ),
                        ),
                      ),
                      // A meal's groceries action goes under its name, so the name keeps the
                      // row's width.
                      if (meal) Hang(by: onSend == null ? 0 : 12, child: end),
                    ],
                  ),
                ),
              ),
              if (!meal) ...[
                const SizedBox(width: Sp.s),
                ExcludeSemantics(child: end),
              ],
            ],
          ),
        ),
      ),
    );
    if (onRemove == null) return row;
    return Dismissible(
      key: ValueKey('dismiss-${item.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onRemove!(),
      background: ColoredBox(
        color: c.destructive,
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.l),
            child: Text('Remove', style: t.label(c.onPrimary)),
          ),
        ),
      ),
      child: row,
    );
  }
}

/// Change an item's words, quantity or store, or remove it.
class _ItemSheet extends StatefulWidget {
  const _ItemSheet({required this.item, required this.kind, required this.onRemove});
  final Item item;
  final ListKind kind;
  final VoidCallback onRemove;

  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  late final _text = TextEditingController(text: widget.item.text);
  late final _qty = TextEditingController(text: widget.item.qty ?? '');
  late final _store = TextEditingController(text: widget.item.store ?? '');
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    _qty.dispose();
    _store.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'An item needs words. To get rid of it, remove it instead.');
      return;
    }
    final nav = Navigator.of(context);
    final ok = await attempt(
      context,
      () => context.listActions.edit(
        widget.item,
        text: text,
        qty: _qty.text.trim().isEmpty ? null : _qty.text.trim(),
        store: _store.text.trim().isEmpty ? null : _store.text.trim(),
      ),
    );
    if (ok) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final shopping = widget.kind == ListKind.shopping;
    final withQty = widget.kind == ListKind.shopping || widget.kind == ListKind.packing;
    Widget field(
      String label,
      TextEditingController controller, {
      bool autofocus = false,
      TextCapitalization caps = TextCapitalization.sentences,
      double top = Sp.l,
    }) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(DenLayout.headingInset, top, 0, Sp.xs),
              child: Text(label, style: t.meta(c.ink2)),
            ),
            TextField(
              controller: controller,
              autofocus: autofocus,
              textCapitalization: caps,
              style: t.body(c.ink),
              onSubmitted: (_) => _save(),
            ),
          ],
        );
    // The sheet itself rises over the keyboard.
    return Padding(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(title: 'Edit item'),
          field('Item', _text, autofocus: true, top: 0),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Sp.xs),
              child: Text(_error!, style: t.meta(c.destructive)),
            ),
          Row(
            children: [
              if (withQty) Expanded(child: field('How many', _qty)),
              if (withQty && shopping) const SizedBox(width: Sp.s),
              if (shopping) Expanded(flex: 2, child: field('Store', _store, caps: TextCapitalization.words)),
            ],
          ),
          const SizedBox(height: Sp.xl),
          Row(
            children: [
              // Its icon lines up with the fields above, on the gutter.
              Hang(
                by: Sp.m,
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: c.destructive),
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onRemove();
                  },
                  icon: const Icon(PhosphorIconsRegular.trash, size: 20),
                  label: const Text('Remove'),
                ),
              ),
              const Spacer(),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ],
      ),
    );
  }
}
