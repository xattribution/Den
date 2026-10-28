import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/forms/forms.dart' show FormWidth;
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../state/lists_model.dart';
import '../widgets/list_content.dart';
import '../widgets/list_menu.dart';

/// One list on its own page, for links from elsewhere (Today, Needs you, Add): the same body as
/// the Lists tab under the list's name. `/lists/:id`.
class ListDetailScreen extends StatelessWidget {
  const ListDetailScreen({super.key, required this.id, this.focusAdd = false});

  final String id;

  /// Opens with the add field focused (Add's "Grocery item").
  final bool focusAdd;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(listReads);
    final lv = app.den.list(id);
    if (lv == null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          message: 'This list was deleted, or it isn\'t shared with you.',
          actionLabel: 'Go to lists',
          onAction: () => context.go('/lists'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(lv.list.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'More for ${lv.list.title}',
            onPressed: () async {
              final keep = Navigator.of(context, rootNavigator: true).context;
              final actions = context.actions;
              final deleted = await showListMenu(context, lv);
              if (deleted == null || !context.mounted) return;
              context.go('/lists');
              // The page is gone with its list; Undo goes with the Lists tab's note instead.
              final receipt = deleted.receipt;
              if (receipt != null && keep.mounted) {
                showUndo(keep, deleted.message, () => attempt(keep, () => actions.undo(receipt)));
              }
            },
            icon: const Icon(PhosphorIconsBold.dotsThree),
          ),
          const SizedBox(width: Sp.xs),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(DenLayout.gutter, Sp.s, DenLayout.gutter, Sp.xxl),
        children: [FormWidth(max: 760, child: ListContent(list: lv, focusAdd: focusAdd))],
      ),
    );
  }
}
