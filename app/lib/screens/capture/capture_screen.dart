import 'dart:async';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart' show CaptureKind;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../capture/capture_controller.dart';
import '../../capture/capture_service.dart';
import '../../capture/capture_settings.dart';
import '../../design/parts/family_frame.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import '../events/event_detail.dart' show closePage;
import '../history/history_words.dart' show routeForRecord;
import 'capture_edit.dart';
import 'capture_words.dart';

/// `/capture`: reads what someone typed, said, photographed or shared, then shows what Den
/// found. In direct mode what needs no look is already added, with Undo; everything else waits
/// here to be chosen, fixed or dropped.
class CaptureRoute extends StatefulWidget {
  const CaptureRoute({super.key, this.input});
  final CaptureInput? input;

  @override
  State<CaptureRoute> createState() => _CaptureRouteState();
}

class _CaptureRouteState extends State<CaptureRoute> {
  CaptureController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final input = widget.input;
    if (_controller != null || input == null) return;
    _controller = CaptureController(service: Capture.of(context), den: context.den, input: input);
    unawaited(_controller!.start());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return FormFrame(
        title: 'Add',
        children: [EmptyLine(message: 'There\'s nothing to read here.', actionLabel: 'Back', onAction: () => closePage(context))],
      );
    }
    return CaptureScreen(controller: controller);
  }
}

class CaptureScreen extends StatelessWidget {
  const CaptureScreen({super.key, required this.controller});
  final CaptureController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = context.colors;
        final kind = controller.input.kind;
        final tray = controller.tray;
        final chosen = tray.where((e) => controller.chosen.contains(e.key)).length;
        final ready = controller.stage == CaptureStage.ready;
        return FormFrame(
          title: captureTitle(kind),
          maxWidth: 720,
          bottom: !ready
              ? null
              : Row(
                  children: [
                    if (tray.isNotEmpty && chosen < tray.length)
                      Expanded(
                        child: Text(
                          tray.length - chosen == 1 ? '1 not chosen' : '${tray.length - chosen} not chosen',
                          style: context.type.meta(c.ink2),
                        ),
                      )
                    else
                      const Spacer(),
                    if (chosen > 0)
                      FilledButton(
                        onPressed: controller.busy ? null : controller.add,
                        child: Text(addWords(chosen)),
                      )
                    else
                      OutlinedButton(onPressed: () => closePage(context), child: const Text('Done')),
                  ],
                ),
          children: switch (controller.stage) {
            CaptureStage.reading => [_Reading(kind: kind)],
            CaptureStage.failed => [_Failed(controller: controller)],
            CaptureStage.ready => _found(context),
          },
        );
      },
    );
  }

  List<Widget> _found(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final result = controller.result!;
    final draft = controller.draft!;
    final tray = controller.tray;
    final events = tray.whereType<DraftEvent>().toList();
    final chores = tray.whereType<DraftChore>().toList();
    final reminders = tray.whereType<DraftReminder>().toList();
    final lists = <String, List<DraftItem>>{};
    final newLists = <String>{};
    for (final i in tray.whereType<DraftItem>()) {
      final (name, isNew) = itemList(app, i);
      lists.putIfAbsent(name, () => []).add(i);
      if (isNew) newLists.add(name);
    }

    Widget section(String title, List<DraftEntry> entries, {String? trailing}) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(title, trailing: trailing ?? '${entries.length}'),
            for (final e in entries) _EntryRow(controller: controller, entry: e),
          ],
        );

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0),
        child: Text(
          [readerWords(result.reader), ?result.note].join('. '),
          style: context.type.meta(c.ink2),
        ),
      ),
      if (controller.addedCount > 0) ...[
        _Added(controller: controller),
        for (final e in controller.done) _DoneRow(controller: controller, entry: e),
      ],
      if (draft.isEmpty) const EmptyLine(message: 'Den didn\'t find anything to add in that.'),
      if (events.isNotEmpty) section('Events', events),
      if (chores.isNotEmpty) section('Chores', chores),
      for (final e in lists.entries) section(e.key, e.value, trailing: newLists.contains(e.key) ? 'New list' : null),
      if (reminders.isNotEmpty) section('Reminders', reminders),
      if (draft.unclear.isNotEmpty) ...[
        const SectionHeader('Den couldn\'t place'),
        for (final u in draft.unclear)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.s),
            child: Text(u, style: context.type.body(c.ink2)),
          ),
      ],
      if (result.read.trim().isNotEmpty)
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: Sp.l),
            childrenPadding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.l),
            title: Text('What Den read', style: context.type.body(c.ink2)),
            expandedAlignment: Alignment.topLeft,
            children: [SelectableText(result.read, style: context.type.meta(c.ink2))],
          ),
        ),
    ];
  }
}

class _Reading extends StatelessWidget {
  const _Reading({required this.kind});
  final CaptureKind kind;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final settings = Capture.of(context).settings;
    final where = switch (settings.reader) {
      ReaderChoice.device => 'Nothing leaves this device.',
      ReaderChoice.home => settings.deviceFirst ? 'On this device first, then the home model if it needs help.' : 'The home model is reading it.',
      ReaderChoice.claude => settings.deviceFirst ? 'On this device first, then Claude if it needs help.' : 'Claude is reading it.',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xxl, Sp.l, Sp.l),
      child: Row(
        children: [
          SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: c.ink)),
          const SizedBox(width: Sp.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(readingWords(kind), style: context.type.bodyStrong(c.ink)),
                Text(where, style: context.type.meta(c.ink2)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.controller});
  final CaptureController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xl, Sp.l, Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AttentionLine(message: controller.error ?? 'Den couldn\'t read that.', bad: true),
          const SizedBox(height: Sp.m),
          Wrap(
            spacing: Sp.s,
            children: [
              if (controller.canRetry) FilledButton(onPressed: controller.start, child: const Text('Try again')),
              OutlinedButton(onPressed: () => closePage(context), child: const Text('Back')),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Added 6 things" with Undo: saved state shown inline, where the person is looking.
class _Added extends StatelessWidget {
  const _Added({required this.controller});
  final CaptureController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = controller.addedCount;
    return Container(
      margin: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.l, 0),
      padding: const EdgeInsets.fromLTRB(Sp.m, Sp.xs, Sp.xs, Sp.xs),
      decoration: BoxDecoration(color: c.well, borderRadius: BorderRadius.circular(Radii.control)),
      child: Row(
        children: [
          Icon(PhosphorIconsBold.check, size: 18, color: c.ink),
          const SizedBox(width: Sp.s),
          Expanded(child: Text(n == 1 ? 'Added 1 thing' : 'Added $n things', style: context.type.bodyStrong(c.ink))),
          TextButton(onPressed: controller.busy ? null : controller.undo, child: const Text('Undo')),
        ],
      ),
    );
  }
}

/// What one added entry became, in words, opening it on tap.
class _DoneRow extends StatelessWidget {
  const _DoneRow({required this.controller, required this.entry});
  final CaptureController controller;
  final DraftEntry entry;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final e = entry;
    final record = controller.records[e.key];
    final route = record == null ? null : routeForRecord(app, record.type, record.id);
    final detail = switch (e) {
      DraftEvent() => eventWhen(app, e),
      DraftChore() => choreWhen(app, e),
      DraftItem() => [itemList(app, e).$1, itemDetail(e)].where((s) => s.isNotEmpty).join(' · '),
      DraftReminder() => reminderWhen(app, e),
    };
    return InkWell(
      onTap: route == null ? null : () => context.push(route),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.s),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: Sp.m),
              child: Icon(PhosphorIconsRegular.check, size: 18, color: c.ink2),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.title, style: context.type.body(c.ink)),
                  Text(detail, style: context.type.meta(c.ink2)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.controller, required this.entry});
  final CaptureController controller;
  final DraftEntry entry;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final e = entry;
    final chosen = controller.chosen.contains(e.key);
    final detail = switch (e) {
      DraftEvent() => [eventWhen(app, e), if (e.location.isNotEmpty) e.location].join(' · '),
      DraftChore() => choreWhen(app, e),
      DraftItem() => itemDetail(e),
      DraftReminder() => reminderWhen(app, e),
    };
    final people = entryPeople(e);
    return InkWell(
      onTap: () => editEntry(context, controller, e),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Sp.xs, Sp.xs, Sp.l, Sp.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CheckDot(
              done: chosen,
              label: '${chosen ? 'Chosen' : 'Not chosen'}: ${e.title}',
              onChanged: e.blocked || controller.busy ? null : (_) => controller.toggle(e.key),
            ),
            Padding(
              padding: const EdgeInsets.only(top: Sp.s, right: Sp.m),
              child: SizedBox(
                height: 36,
                child: e is DraftItem ? const SizedBox(width: 4) : PersonBar(markers: app.markersFor(people), minHeight: 36),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: Sp.s),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.title, style: context.type.body(c.ink)),
                    if (detail.isNotEmpty) Text(detail, style: context.type.meta(c.ink2)),
                    for (final i in e.issues) AttentionLine(message: i.message, bad: i.blocking),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
