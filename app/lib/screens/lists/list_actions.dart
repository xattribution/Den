import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design/widgets.dart';
import '../../state/app_state.dart';

/// Deletes a list and offers Undo, which brings the same list back with its items.
Future<void> deleteListWithUndo(BuildContext context, ListState lv) async {
  final den = context.den;
  final keep = Navigator.of(context, rootNavigator: true).context;
  final ok = await attempt(context, () => den.deleteList(lv.list.id));
  if (!ok || !context.mounted) return;
  context.go('/lists');
  if (!keep.mounted) return;
  showUndo(keep, '${lv.list.title} deleted', () => attempt(keep, () => den.restore(RecordType.list, lv.list.id)));
}

/// Puts removed items back exactly as they were, checked or not and in their places, in one
/// change.
Future<bool> restoreItems(BuildContext context, Den den, List<String> ids) =>
    attempt(context, () => den.restoreAll(RecordType.item, ids));
