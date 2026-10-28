import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/forms/fields.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../state/list_actions.dart';
import 'list_share.dart';
import '../words/list_words.dart';

/// One list. Items keep their places: a checked item stays where it was, struck through.
/// Shopping lists group and filter by store. The add row sits at the bottom with separate
/// item, quantity and store fields; the store sticks between adds. `/lists/:id`.
class ListDetailScreen extends StatefulWidget {
  const ListDetailScreen({super.key, required this.id, this.focusAdd = false});

  final String id;

  /// Opens with the add row focused (the Add sheet's "Grocery item").
  final bool focusAdd;

  @override
  State<ListDetailScreen> createState() => _ListDetailScreenState();
}

class _ListDetailScreenState extends State<ListDetailScreen> {
  bool _byStore = false;

  /// Null shows every store; the empty string shows items without one.
  String? _store;

  /// Items removed here whose removal the engine hasn't reported yet, so a swiped row leaves
  /// the tree at once.
  final Set<String> _hidden = {};

  /// The order after a drag, shown until the engine's order catches up.
  List<String>? _optimistic;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<Item> _visibleItems(ListState lv) {
    var items = lv.items.where((i) => !_hidden.contains(i.id)).toList();
    final pending = _optimistic;
    if (pending != null) {
      final ids = items.map((i) => i.id).toList();
      if (ids.join(',') == pending.join(',') ||
          ids.toSet().length != pending.toSet().length ||
          !ids.toSet().containsAll(pending)) {
        _optimistic = null;
      } else {
        final byId = {for (final i in items) i.id: i};
        items = [for (final id in pending) byId[id]!];
      }
    }
    return items;
  }

  Future<void> _remove(ListState lv, Item item) async {
    final den = context.den;
    final keep = Navigator.of(context, rootNavigator: true).context;
    setState(() => _hidden.add(item.id));
    final ok = await attempt(context, () => den.removeItem(item.id));
    if (!mounted) return;
    if (!ok) {
      setState(() => _hidden.remove(item.id));
      return;
    }
    showUndo(context, '${item.text} removed', () => _restore(keep, den, [item.id]));
  }

  Future<void> _clearDone(ListState lv) async {
    final den = context.den;
    final keep = Navigator.of(context, rootNavigator: true).context;
    final done = [for (final i in lv.items) if (i.checked) i.id];
    var count = 0;
    final ok = await attempt(context, () async => count = await den.clearChecked(lv.list.id));
    if (!ok || !mounted) return;
    showUndo(context, 'Cleared $count done ${count == 1 ? 'item' : 'items'}', () => _restore(keep, den, done));
  }

  /// Undo: the same items come back where they were, checked or not, in one change. [keep]
  /// outlives this page, since Undo can be tapped after leaving it.
  void _restore(BuildContext keep, Den den, List<String> ids) {
    if (mounted) setState(() => _hidden.removeAll(ids));
    restoreItems(keep, den, ids);
  }

  void _reorder(List<Item> items, int from, int to) {
    if (to > from) to--;
    if (from == to) return;
    final moved = items[from];
    final rest = [...items]..removeAt(from);
    final after = to > 0 ? rest[to - 1].id : null;
    final before = to < rest.length ? rest[to].id : null;
    rest.insert(to, moved);
    setState(() => _optimistic = rest.map((i) => i.id).toList());
    attempt(context, () => context.den.moveItem(moved.id, after: after, before: before));
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: Motion.of(context, Motion.sheet),
          curve: Motion.curve,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final c = context.colors;
    final lv = den.list(widget.id);
    if (lv == null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyLine(
          message: 'This list was deleted, or it isn\'t shared with you.',
          actionLabel: 'Go to lists',
          onAction: () => context.go('/lists'),
        ),
      );
    }

    final canEdit = app.canChangeItems;
    final canCheck = app.allows(DenAction.checkItems);
    final items = _visibleItems(lv);
    final storeOrder = den.stores;
    final stores = items.map((i) => i.store ?? '').where((s) => s.isNotEmpty).toSet().toList()
      ..sort((a, b) {
        final ia = storeOrder.indexOf(a);
        final ib = storeOrder.indexOf(b);
        if (ia != ib) return (ia < 0 ? 999 : ia).compareTo(ib < 0 ? 999 : ib);
        return a.compareTo(b);
      });
    final hasNoStore = items.any((i) => (i.store ?? '').isEmpty);
    if (_store != null && _store!.isNotEmpty && !stores.contains(_store)) _store = null;
    if (_store == '' && !hasNoStore) _store = null;
    final filtered = _store == null ? items : items.where((i) => (i.store ?? '') == _store).toList();
    final grouped = _byStore && stores.isNotEmpty;
    final reorderable = canEdit && !grouped && _store == null && filtered.length > 1;
    final doneCount = items.where((i) => i.checked).length;

    Widget row(Item item, {int? dragIndex}) => _ItemRow(
      key: ValueKey(item.id),
      item: item,
      kind: lv.list.kind,
      showStore: !grouped && _store == null,
      dragIndex: dragIndex,
      canCheck: canCheck,
      onRemove: canEdit ? () => _remove(lv, item) : null,
      onEdit: canEdit ? () => _editItem(lv, item) : null,
    );

    final clear = canEdit && doneCount > 0 && _store == null
        ? Padding(
            key: const ValueKey('clear-done'),
            padding: const EdgeInsets.fromLTRB(Sp.s, Sp.m, Sp.l, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _clearDone(lv),
                icon: const Icon(PhosphorIconsRegular.broom, size: 18),
                label: Text('Clear $doneCount done ${doneCount == 1 ? 'item' : 'items'}'),
              ),
            ),
          )
        : null;

    Widget content;
    if (items.isEmpty) {
      content = ListView(children: const [EmptyLine(message: 'Nothing on this list yet.')]);
    } else if (filtered.isEmpty) {
      content = ListView(
        children: [EmptyLine(message: _store == '' ? 'Every item has a store.' : 'Nothing at $_store.')],
      );
    } else if (reorderable) {
      content = ReorderableListView.builder(
        scrollController: _scroll,
        padding: const EdgeInsets.only(top: Sp.xs, bottom: Sp.xl),
        buildDefaultDragHandles: false,
        itemCount: filtered.length,
        footer: clear,
        proxyDecorator: (child, _, _) =>
            Material(color: c.paper, elevation: 8, shadowColor: c.ink.withValues(alpha: 0.18), child: child),
        onReorder: (from, to) => _reorder(filtered, from, to),
        itemBuilder: (context, i) => row(filtered[i], dragIndex: i),
      );
    } else {
      final groups = <String, List<Item>>{};
      if (grouped) {
        for (final s in [...stores, if (hasNoStore) '']) {
          final inStore = filtered.where((i) => (i.store ?? '') == s).toList();
          if (inStore.isNotEmpty) groups[s] = inStore;
        }
      }
      content = ListView(
        controller: _scroll,
        padding: const EdgeInsets.only(top: Sp.xs, bottom: Sp.xl),
        children: [
          if (grouped)
            for (final (gi, entry) in groups.entries.indexed) ...[
              _StoreHeading(store: entry.key, items: entry.value, first: gi == 0),
              for (final item in entry.value) row(item),
            ]
          else
            for (final item in filtered) row(item),
          ?clear,
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(lv.list.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Share list',
            onPressed: () => showShareSheet(context, lv),
            icon: const Icon(PhosphorIconsRegular.shareNetwork),
          ),
          if (canEdit)
            PopupMenuButton<String>(
              tooltip: 'List options',
              icon: const Icon(PhosphorIconsRegular.dotsThreeVertical),
              onSelected: (v) {
                if (v == 'edit') context.push('/lists/${lv.list.id}/edit');
                if (v == 'delete') deleteListWithUndo(context, lv);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit list')),
                PopupMenuItem(value: 'delete', child: Text('Delete list')),
              ],
            ),
          const SizedBox(width: Sp.xs),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: FormWidth(
              max: _maxWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (stores.isNotEmpty)
                    _StoreBar(
                      stores: stores,
                      hasNoStore: hasNoStore,
                      items: items,
                      byStore: _byStore,
                      store: _store,
                      onByStore: (v) => setState(() => _byStore = v),
                      onStore: (s) => setState(() => _store = s),
                    ),
                  if (timingOf(app, lv) case final timing?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.xs),
                      child: timing.late
                          ? AttentionLine(bad: true, message: timing.text)
                          : Text(timing.text, style: context.type.meta(c.ink2)),
                    ),
                  Expanded(child: content),
                ],
              ),
            ),
          ),
          if (canEdit) ...[
            Divider(height: 1, color: c.rule),
            FormWidth(
              max: _maxWidth,
              child: AddItemRow(
                listId: lv.list.id,
                kind: lv.list.kind,
                autofocus: widget.focusAdd,
                onAdded: _scrollToEnd,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Items read as a list, not a table: past this width rows stop growing.
  static const double _maxWidth = 760;

  ({String text, bool late})? timingOf(AppState app, ListState lv) => listTiming(app, lv);

  Future<void> _editItem(ListState lv, Item item) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ItemSheet(item: item, kind: lv.list.kind, onRemove: () => _remove(lv, item)),
    );
  }
}

/// Store controls for shopping lists: the "By store" grouping toggle, then a chip per store to
/// show only what's bought there. Stores are words in ink, never colors.
class _StoreBar extends StatelessWidget {
  const _StoreBar({
    required this.stores,
    required this.hasNoStore,
    required this.items,
    required this.byStore,
    required this.store,
    required this.onByStore,
    required this.onStore,
  });

  final List<String> stores;
  final bool hasNoStore;
  final List<Item> items;
  final bool byStore;
  final String? store;
  final ValueChanged<bool> onByStore;
  final ValueChanged<String?> onStore;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    int open(String s) => items.where((i) => !i.checked && (i.store ?? '') == s).length;
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Sp.l),
        children: [
          InkChip(
            icon: PhosphorIconsRegular.storefront,
            label: 'By store',
            selected: byStore,
            onTap: () => onByStore(!byStore),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.s, vertical: Sp.m),
            child: VerticalDivider(width: 1, color: c.rule),
          ),
          InkChip(label: 'All stores', selected: store == null, onTap: () => onStore(null)),
          for (final s in stores) ...[
            const SizedBox(width: Sp.s),
            InkChip(label: s, count: open(s), selected: store == s, onTap: () => onStore(store == s ? null : s)),
          ],
          if (hasNoStore) ...[
            const SizedBox(width: Sp.s),
            InkChip(
              label: 'No store',
              count: open(''),
              selected: store == '',
              onTap: () => onStore(store == '' ? null : ''),
            ),
          ],
        ],
      ),
    );
  }
}

class _StoreHeading extends StatelessWidget {
  const _StoreHeading({required this.store, required this.items, required this.first});
  final String store;
  final List<Item> items;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final left = items.where((i) => !i.checked).length;
    return Padding(
      padding: EdgeInsets.fromLTRB(Sp.l, first ? Sp.s : Sp.xl, Sp.l, Sp.xs),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            Expanded(child: Text(store.isEmpty ? 'No store' : store, style: context.type.bodyStrong(c.ink))),
            Text(left == 0 ? 'All done' : '$left left', style: context.type.meta(c.ink2)),
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.item,
    required this.kind,
    required this.showStore,
    required this.dragIndex,
    required this.canCheck,
    required this.onRemove,
    required this.onEdit,
  });

  final Item item;
  final ListKind kind;
  final bool showStore;
  final int? dragIndex;
  final bool canCheck;
  final VoidCallback? onRemove;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final checked = item.checked;
    void toggle() => attempt(context, () => app.den.setItemChecked(item.id, !checked));
    final qty = item.qty ?? '';
    final store = item.store ?? '';

    final row = Semantics(
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Edit item'): ?onEdit,
        const CustomSemanticsAction(label: 'Remove item'): ?onRemove,
      },
      child: InkWell(
        onTap: canCheck ? toggle : null,
        onLongPress: onEdit,
        onSecondaryTap: onEdit,
        child: Padding(
          padding: EdgeInsets.only(left: Sp.xs, right: dragIndex == null ? Sp.l : 0),
          child: Row(
            children: [
              CheckDot(done: checked, label: item.text, onChanged: canCheck ? (_) => toggle() : null),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.m),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: item.text,
                          style: context.type
                              .body(checked ? c.ink2 : c.ink)
                              .copyWith(
                                decoration: checked ? TextDecoration.lineThrough : null,
                                decorationColor: c.ink2,
                              ),
                        ),
                        if (qty.isNotEmpty) TextSpan(text: '   $qty', style: context.type.meta(c.ink2)),
                      ],
                    ),
                  ),
                ),
              ),
              if (showStore && store.isNotEmpty) ...[
                const SizedBox(width: Sp.s),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(store, style: context.type.meta(c.ink2), overflow: TextOverflow.ellipsis),
                ),
              ],
              if (kind == ListKind.meal) ...[const SizedBox(width: Sp.s), _GroceriesAction(item)],
              if (dragIndex != null)
                ReorderableDragStartListener(
                  index: dragIndex!,
                  child: Tooltip(
                    message: 'Drag to reorder',
                    child: SizedBox.square(
                      dimension: Targets.adult,
                      child: Icon(PhosphorIconsRegular.dotsSixVertical, size: 20, color: c.ink3),
                    ),
                  ),
                ),
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
      background: Container(
        color: c.bad,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: Sp.l),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PhosphorIconsRegular.trash, size: 20, color: c.paper),
            const SizedBox(width: Sp.s),
            Text('Remove', style: context.type.bodyStrong(c.paper)),
          ],
        ),
      ),
      child: row,
    );
  }
}

/// On a meal list: a cart button sends one item to the groceries list (the add row's "Also add
/// to groceries" names it); once there, the row says so in words.
class _GroceriesAction extends StatelessWidget {
  const _GroceriesAction(this.item);
  final Item item;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    if (item.toGroceries) {
      return Padding(
        padding: const EdgeInsets.only(left: Sp.s),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PhosphorIconsBold.check, size: 14, color: c.ink2),
            const SizedBox(width: Sp.xs),
            Text('On groceries', style: context.type.meta(c.ink2)),
          ],
        ),
      );
    }
    if (!app.canChangeItems) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Also add to groceries',
      icon: Icon(PhosphorIconsRegular.shoppingCartSimple, size: 20, color: c.ink2),
      onPressed: () async {
        final den = app.den;
        final groceries = groceriesList(den);
        if (groceries == null) {
          showNote(context, 'There\'s no shopping list to add to. Add one in Lists, then try again.');
          return;
        }
        // Marking a meal item for groceries copies it onto the groceries list.
        await attempt(context, () => den.updateItem(item.id, {'toGroceries': true}));
      },
    );
  }
}

/// The add row: item, quantity and store as separate fields. Enter adds; the store stays for
/// the next item and known stores are one tap away.
class AddItemRow extends StatefulWidget {
  const AddItemRow({super.key, required this.listId, required this.kind, this.autofocus = false, this.onAdded});

  final String listId;
  final ListKind kind;
  final bool autofocus;
  final VoidCallback? onAdded;

  @override
  State<AddItemRow> createState() => _AddItemRowState();
}

class _AddItemRowState extends State<AddItemRow> {
  final _text = TextEditingController();
  final _qty = TextEditingController();
  final _store = TextEditingController();
  final _focus = FocusNode();
  bool _toGroceries = false;

  bool get _shopping => widget.kind == ListKind.shopping;
  bool get _hasQty => widget.kind == ListKind.shopping || widget.kind == ListKind.packing;

  @override
  void initState() {
    super.initState();
    _store.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _qty.dispose();
    _store.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      _focus.requestFocus();
      return;
    }
    final qty = _qty.text.trim();
    final store = _store.text.trim();
    final ok = await attempt(
      context,
      () => context.den.addItem(
        widget.listId,
        text: text,
        qty: qty.isEmpty ? null : qty,
        store: _shopping && store.isNotEmpty ? store : null,
        toGroceries: widget.kind == ListKind.meal && _toGroceries,
      ),
    );
    if (!ok || !mounted) return;
    _text.clear();
    _qty.clear();
    _focus.requestFocus();
    widget.onAdded?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final known = _shopping ? context.den.stores.take(8).toList() : const <String>[];
    final current = _store.text.trim();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.l, Sp.m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    autofocus: widget.autofocus,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.done,
                    onEditingComplete: _add,
                    style: context.type.body(c.ink),
                    decoration: const InputDecoration(hintText: 'Item', isDense: false),
                  ),
                ),
                if (_hasQty) ...[
                  const SizedBox(width: Sp.s),
                  SizedBox(
                    width: 72,
                    child: TextField(
                      controller: _qty,
                      textInputAction: TextInputAction.done,
                      onEditingComplete: _add,
                      style: context.type.body(c.ink),
                      decoration: const InputDecoration(hintText: 'Qty'),
                    ),
                  ),
                ],
                const SizedBox(width: Sp.s),
                FilledButton(onPressed: _add, child: const Text('Add item')),
              ],
            ),
            if (_shopping) ...[
              const SizedBox(height: Sp.s),
              Row(
                children: [
                  SizedBox(
                    width: 148,
                    child: TextField(
                      controller: _store,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.done,
                      onEditingComplete: _add,
                      style: context.type.body(c.ink),
                      decoration: InputDecoration(
                        hintText: 'Store',
                        suffixIcon: current.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear store',
                                onPressed: _store.clear,
                                icon: Icon(PhosphorIconsRegular.x, size: 16, color: c.ink2),
                              ),
                      ),
                    ),
                  ),
                  if (known.isNotEmpty) ...[
                    const SizedBox(width: Sp.s),
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final s in known) ...[
                              InkChip(
                                label: s,
                                selected: s.toLowerCase() == current.toLowerCase(),
                                onTap: () {
                                  _store.text = s.toLowerCase() == current.toLowerCase() ? '' : s;
                                  _focus.requestFocus();
                                },
                              ),
                              const SizedBox(width: Sp.s),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
            if (widget.kind == ListKind.meal)
              Align(
                alignment: Alignment.centerLeft,
                child: InkChip(
                  icon: PhosphorIconsRegular.shoppingCart,
                  label: 'Also add to groceries',
                  selected: _toGroceries,
                  onTap: () => setState(() => _toGroceries = !_toGroceries),
                ),
              ),
          ],
        ),
      ),
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
    final ok = await attempt(context, () {
      return context.den.updateItem(widget.item.id, {
        'text': text,
        'qty': _qty.text.trim().isEmpty ? null : _qty.text.trim(),
        'store': _store.text.trim().isEmpty ? null : _store.text.trim(),
      });
    });
    if (ok) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final shopping = widget.kind == ListKind.shopping;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.l + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(header: true, child: Text('Edit item', style: context.type.title(c.ink))),
            const FieldLabel('Item', top: Sp.l),
            TextField(controller: _text, autofocus: true, style: context.type.body(c.ink), onSubmitted: (_) => _save()),
            FieldError(_error),
            Row(
              children: [
                if (widget.kind != ListKind.checklist && widget.kind != ListKind.meal)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const FieldLabel('Qty', top: Sp.l),
                        TextField(controller: _qty, style: context.type.body(c.ink), onSubmitted: (_) => _save()),
                      ],
                    ),
                  ),
                if (shopping) ...[
                  const SizedBox(width: Sp.s),
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const FieldLabel('Store', top: Sp.l),
                        TextField(
                          controller: _store,
                          textCapitalization: TextCapitalization.words,
                          style: context.type.body(c.ink),
                          onSubmitted: (_) => _save(),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: Sp.l),
            Row(
              children: [
                DestructiveButton(
                  label: 'Remove item',
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onRemove();
                  },
                ),
                const Spacer(),
                FilledButton(onPressed: _save, child: const Text('Save item')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
