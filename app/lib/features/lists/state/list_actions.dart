import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/actions.dart';
import '../../../app/den_scope.dart';

/// Every change the lists screens make (and the wall makes to lists), each one a den_actions
/// action.
class ListActions {
  const ListActions(this._actions);

  final AppActions _actions;

  /// Adds a list, or changes [existing]. The [lifecycle] picks which of [needBy] and [event]
  /// counts; [audience] is null when who sees it stays as it is.
  Future<ActionResult> save(
    ListState? existing, {
    required String title,
    required ListKind kind,
    required ListLifecycle lifecycle,
    required String? needBy,
    required String? event,
    required bool pinned,
    Audience? audience,
  }) {
    final dated = lifecycle == ListLifecycle.dated;
    final forEvent = lifecycle == ListLifecycle.event;
    return _actions.run(existing == null ? 'create_list' : 'update_list', {
      if (existing != null) 'list': existing.list.id,
      'title': title,
      'kind': kind.name,
      'pinned': pinned,
      if (existing == null) ...{
        if (dated) 'need_by': needBy,
        if (forEvent) 'event': event,
      } else ...{
        // A list for an event says only the event; the action clears its need-by date.
        if (!forEvent) 'need_by': dated ? needBy : '',
        'event': forEvent ? event : '',
      },
      if (audience != null) 'who_can_see': whoCanSee(audience),
    });
  }

  /// Removes [list] with its items; its receipt brings them back.
  Future<ActionResult> delete(ListState list) => _actions.run('delete_list', {'list': list.list.id});

  /// Adds an item to the end of [listId].
  Future<ActionResult> addItem(String listId, String text, {String? qty, String? store, bool toGroceries = false}) =>
      _actions.run('add_items', {
        'list': listId,
        'items': [
          {'text': text, 'qty': qty, 'store': store, if (toGroceries) 'to_groceries': true},
        ],
      });

  /// Adds several items at once (the add field's "2 milk @Costco, eggs"); one receipt takes
  /// them all back.
  Future<ActionResult> addItems(String listId, List<({String text, String? qty, String? store})> items) =>
      _actions.run('add_items', {
        'list': listId,
        'items': [
          for (final i in items) {'text': i.text, 'qty': i.qty, 'store': i.store},
        ],
      });

  /// Checks [item] off, or not.
  Future<ActionResult> setChecked(Item item, bool checked) => _change(item, {'checked': checked});

  /// Changes [item]'s words, quantity and store (null clears the last two).
  Future<ActionResult> edit(Item item, {required String text, String? qty, String? store}) =>
      _change(item, {'text': text, 'qty': qty ?? '', 'store': store ?? ''});

  /// Puts a meal plan's [item] on the groceries too.
  Future<ActionResult> sendToGroceries(Item item) => _change(item, {'to_groceries': true});

  /// Moves [item] between [after] and [before] (item ids; null at either end).
  Future<ActionResult> move(Item item, {String? after, String? before}) =>
      _change(item, {'after': after, 'before': before});

  Future<ActionResult> _change(Item item, Map<String, Object?> what) => _actions.run('update_items', {
        'items': [
          {'item': item.id, 'list': item.list, ...what},
        ],
      });

  /// Removes [item]; its receipt puts it back where it was.
  Future<ActionResult> remove(Item item) => _actions.run('remove_items', {
        'list': item.list,
        'items': [item.id],
      });

  /// Removes every checked item on [listId]; its receipt puts them all back.
  Future<ActionResult> clearChecked(String listId) => _actions.run('remove_items', {'list': listId, 'checked': true});
}

extension ListActionsOf on BuildContext {
  /// The lists' actions. Reading them never rebuilds.
  ListActions get listActions => ListActions(actions);
}

/// Deletes a list and offers Undo, which brings the same list back with its items.
Future<void> deleteListWithUndo(BuildContext context, ListState lv) async {
  final actions = context.actions;
  final keep = Navigator.of(context, rootNavigator: true).context;
  final result = await perform(context, () => ListActions(actions).delete(lv));
  if (result == null || !context.mounted) return;
  context.go('/lists');
  if (!keep.mounted) return;
  offerUndo(keep, actions, '${lv.list.title} deleted', result);
}
