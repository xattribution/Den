import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../../lists/screens/list_detail.dart';
import '../../lists/words/list_words.dart';

/// The Add sheet's "Grocery item": the first pinned shopping list with its add row focused.
/// `/lists/groceries/add`.
class GroceryAddScreen extends StatelessWidget {
  const GroceryAddScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final target = groceriesList(app.den);
    if (target != null) return ListDetailScreen(id: target.list.id, focusAdd: true);

    final canCreate = app.allows(DenAction.editLists);
    return Scaffold(
      appBar: AppBar(title: const Text('Groceries')),
      body: EmptyLine(
        message: canCreate
            ? 'There\'s no shopping list yet.'
            : 'There\'s no shopping list yet. Ask a parent to add one.',
        actionLabel: canCreate ? 'Add groceries list' : null,
        onAction: () async {
          final den = app.den;
          final ok = await attempt(
            context,
            () => den.addList(title: 'Groceries', kind: ListKind.shopping, icon: 'shopping', pinned: true),
          );
          if (ok && context.mounted) context.pushReplacement('/lists/groceries/add');
        },
      ),
    );
  }
}
