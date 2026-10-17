import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design/widgets.dart';
import '../../state/app_state.dart';

/// Deletes a list and offers Undo, which puts the list and its items back in their order.
Future<void> deleteListWithUndo(BuildContext context, ListState lv) async {
  final den = context.den;
  final keep = Navigator.of(context, rootNavigator: true).context;
  final ok = await attempt(context, () => den.deleteList(lv.list.id));
  if (!ok || !context.mounted) return;
  context.go('/lists');
  if (!keep.mounted) return;
  final list = lv.list;
  showUndo(keep, '${list.title} deleted', () {
    attempt(keep, () async {
      final id = await den.addList(
        title: list.title,
        kind: list.kind,
        lifecycle: list.lifecycle,
        needBy: list.needBy,
        event: list.event,
        icon: list.icon,
        pinned: list.pinned,
        audience: list.audience,
      );
      for (final item in lv.items) {
        final itemId = await den.addItem(id, text: item.text, qty: item.qty, store: item.store);
        if (item.checked) await den.setItemChecked(itemId, true);
      }
    });
  });
}

/// Puts removed items back where they were: each one between the neighbors it had, then checked
/// again if it was. [before] is the list's items before the removal, in order.
Future<void> restoreItems(Den den, String listId, List<Item> before, List<Item> removed) async {
  final removedIds = removed.map((i) => i.id).toSet();
  final originalIndex = {for (final (k, i) in before.indexed) i.id: k};
  final current = [
    for (final i in before)
      if (!removedIds.contains(i.id)) i.id,
  ];
  final currentIndex = [for (final id in current) originalIndex[id]!];
  for (final item in removed) {
    final index = originalIndex[item.id]!;
    final pos = currentIndex.where((x) => x < index).length;
    final id = await den.addItem(listId, text: item.text, qty: item.qty, store: item.store);
    final after = pos > 0 ? current[pos - 1] : null;
    final beforeId = pos < current.length ? current[pos] : null;
    if (after != null || beforeId != null) await den.moveItem(id, after: after, before: beforeId);
    if (item.checked) await den.setItemChecked(id, true);
    current.insert(pos, id);
    currentIndex.insert(pos, index);
  }
}
