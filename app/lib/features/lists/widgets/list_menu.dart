import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../state/list_actions.dart';
import '../state/lists_model.dart';
import '../words/list_words.dart';

/// The list's "More": Share and Copy its open items as text, Reorder them, Edit the list, and
/// Delete it. Completes with what a delete did, so the page can offer Undo in place; Reorder
/// opens its own sheet once this one has closed.
Future<Done?> showListMenu(BuildContext context, ListState lv) async {
  final router = GoRouter.maybeOf(context);
  final picked = await showDenSheet<Object>(
    context,
    builder: (sheet) => _ListMenu(lv: lv, open: (route) => router?.push(route)),
  );
  if (picked == _reorder && context.mounted) {
    await showDenSheet<void>(context, builder: (_) => _Reorder(listId: lv.list.id));
    return null;
  }
  return picked is Done ? picked : null;
}

const Object _reorder = #reorder;

class _ListMenu extends StatefulWidget {
  const _ListMenu({required this.lv, required this.open});
  final ListState lv;
  final void Function(String route) open;

  @override
  State<_ListMenu> createState() => _ListMenuState();
}

class _ListMenuState extends State<_ListMenu> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final app = DenScope.read(context);
    final c = context.colors;
    final t = context.text;
    final lv = widget.lv;
    final text = shareText(lv);
    final empty = lv.open == 0;
    // Another family's list: theirs to rename or delete; one shared only to see, theirs to sort.
    final seeOnly = app.den.seeOnlyList(lv.list);
    final canEdit = app.allows(DenAction.editLists) && lv.list.link == null;
    final canMove = app.canChangeItems && lv.open > 1 && !seeOnly;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.xs, DenLayout.headingInset, Sp.l),
            child: Semantics(header: true, child: Text(lv.list.title, style: t.sheetTitle(c.ink))),
          ),
          GroupCard(
            child: Column(
              children: ruled([
                Builder(
                  builder: (row) => NavRow(
                    icon: PhosphorIconsRegular.shareFat,
                    label: 'Share',
                    detail: empty ? 'Nothing left to share' : 'The open items, as text',
                    chevron: false,
                    onTap: empty
                        ? null
                        : () {
                            final box = row.findRenderObject() as RenderBox?;
                            SharePlus.instance.share(
                              ShareParams(
                                text: text,
                                subject: lv.list.title,
                                sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
                              ),
                            );
                          },
                  ),
                ),
                NavRow(
                  icon: _copied ? PhosphorIconsBold.check : PhosphorIconsRegular.copy,
                  label: _copied ? 'Copied' : 'Copy',
                  chevron: false,
                  onTap: empty
                      ? null
                      : () async {
                          await Clipboard.setData(ClipboardData(text: text));
                          if (mounted) setState(() => _copied = true);
                        },
                ),
                if (canMove)
                  NavRow(
                    icon: PhosphorIconsRegular.arrowsDownUp,
                    label: 'Reorder',
                    chevron: false,
                    onTap: () => Navigator.of(context).pop(_reorder),
                  ),
                if (canEdit)
                  NavRow(
                    icon: PhosphorIconsRegular.pencilSimple,
                    label: 'Edit list',
                    onTap: () {
                      Navigator.of(context).pop();
                      widget.open('/lists/${lv.list.id}/edit');
                    },
                  ),
              ], indent: 36),
            ),
          ),
          if (canEdit) ...[
            const SizedBox(height: Sp.l),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: c.destructive),
                onPressed: () async {
                  final nav = Navigator.of(context);
                  final result = await perform(context, () => context.listActions.delete(lv));
                  if (result == null) return;
                  nav.pop<Object>((message: 'Deleted ${lv.list.title}', receipt: result.receipt));
                },
                icon: const Icon(PhosphorIconsRegular.trash, size: 20),
                label: const Text('Delete list'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The list's open items in their order, to drag into a new one. Each drop moves that item
/// at once.
class _Reorder extends StatefulWidget {
  const _Reorder({required this.listId});
  final String listId;

  @override
  State<_Reorder> createState() => _ReorderState();
}

class _ReorderState extends State<_Reorder> {
  List<String>? _order;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(listReads);
    final c = context.colors;
    final t = context.text;
    final lv = app.den.list(widget.listId);
    if (lv == null) return const SizedBox.shrink();
    final open = [for (final i in lv.items) if (!i.checked) i];
    final byId = {for (final i in open) i.id: i};
    final order = _order?.where(byId.containsKey).toList();
    final items = order != null && order.length == open.length ? [for (final id in order) byId[id]!] : open;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.xs, DenLayout.headingInset, Sp.s),
            child: Row(
              children: [
                Expanded(child: Semantics(header: true, child: Text('Reorder', style: t.sheetTitle(c.ink)))),
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
              ],
            ),
          ),
          Flexible(
            child: GroupCard(
              padding: EdgeInsets.zero,
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                itemCount: items.length,
                proxyDecorator: (child, _, _) => Material(color: c.card, elevation: 6, child: child),
                onReorder: (from, to) {
                  if (to > from) to--;
                  if (from == to) return;
                  final moved = items[from];
                  final rest = [...items]..removeAt(from);
                  final after = to > 0 ? rest[to - 1].id : null;
                  final before = to < rest.length ? rest[to].id : null;
                  rest.insert(to, moved);
                  setState(() => _order = [for (final i in rest) i.id]);
                  attempt(context, () => context.listActions.move(moved, after: after, before: before));
                },
                itemBuilder: (context, i) => ReorderableDragStartListener(
                  key: ValueKey(items[i].id),
                  index: i,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: DenLayout.cardPadding),
                      child: Row(
                        children: [
                          Expanded(child: Text(items[i].text, style: t.body(c.ink))),
                          Icon(PhosphorIconsRegular.dotsSixVertical, size: 22, color: c.ink2),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
