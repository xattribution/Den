import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../app/app_state.dart';
import '../../design/layout.dart';
import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../platform/sync/hub_client.dart' show HubException;
import '../family/family.dart' show ConfirmPanel;
import 'linked_families.dart';

/// One linked family (`/settings/linked/:id`): what they share with this family (their
/// calendar's next events and their lists, each opening where it lives), and, for parents, what
/// this family shares with them (the calendar and each list: Off, See, or Change too) and End
/// link.
class LinkedFamilyScreen extends StatefulWidget {
  const LinkedFamilyScreen({super.key, required this.id, this.source});

  final String id;

  /// Where links are made, for tests; by default the family's hub.
  final FamilyLinksSource? source;

  @override
  State<LinkedFamilyScreen> createState() => _LinkedFamilyScreenState();
}

class _LinkedFamilyScreenState extends State<LinkedFamilyScreen> {
  String? _error;
  bool _ending = false;
  bool _busy = false;
  String? _url;
  bool _copied = false;

  static const Map<ShareLevel?, String> _levels = {null: 'Off', ShareLevel.see: 'See', ShareLevel.edit: 'Change'};

  Future<void> _share(String what, ShareLevel? level) async {
    final den = DenScope.read(context).den;
    final problem = await tryWrite(() => den.shareWithFamily(widget.id, what, level));
    if (mounted) setState(() => _error = problem);
  }

  Future<void> _end() async {
    setState(() => _busy = true);
    final den = DenScope.read(context).den;
    final problem = await tryWrite(() => den.endFamilyLink(widget.id));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
    });
    if (problem == null) context.pop();
  }

  Future<void> _showLink() async {
    final network = DenScope.read(context).network;
    final source = widget.source ?? (network == null ? null : HubFamilyLinks(network));
    if (source == null) return;
    setState(() => _busy = true);
    String? url, failed;
    try {
      url = await source.offer(widget.id);
    } on HubException catch (e) {
      failed = e.message;
    } on Object {
      failed = 'Den couldn\'t reach the family\'s hub. Try again in a minute.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _url = url;
      _error = failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.familyLink, RecordType.list, RecordType.item, RecordType.event});
    final c = context.colors;
    final t = context.text;
    final den = app.den;
    final link = den.familyLink(widget.id);
    if (link == null || link.status == LinkStatus.ended) {
      return DenPage(title: 'Linked family', children: [
        EmptyState(message: 'This link was ended.', actionLabel: 'Linked families', onAction: () => context.go('/settings/linked')),
      ]);
    }
    final parent = app.allows(DenAction.manageFamily);
    final waiting = link.status == LinkStatus.waiting;
    final who = linkedFamilyName(link.name);
    final theirs = link.theirs;
    final now = den.now();
    final events = theirs.containsKey(Shared.calendar)
        ? [
            for (final o in den.occurrences(now, now + const Duration(days: 60).inMilliseconds))
              if (o.event.link == link.id) o,
          ].take(8).toList()
        : const <Occurrence>[];
    final lists = [for (final l in den.lists) if (l.list.link == link.id) l];
    final mine = [for (final l in den.lists) if (l.list.link == null) l];
    final share = link.share;
    final f = app.formats;
    return DenPage(
      title: waiting ? 'Waiting for the other family' : who,
      children: [
        if (link.problem != null) NoticeLine(icon: PhosphorIconsRegular.wifiSlash, message: link.problem!),
        if (waiting && parent) ...[
          GroupCard(
            child: NavRow(
              icon: PhosphorIconsRegular.link,
              label: 'Show the link again',
              chevron: false,
              onTap: _busy ? null : _showLink,
            ),
          ),
          if (_url != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(_url!, style: t.meta(c.ink)),
                const SizedBox(height: Sp.m),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: _url!));
                      if (mounted) setState(() => _copied = true);
                    },
                    icon: Icon(_copied ? PhosphorIconsBold.check : PhosphorIconsRegular.copy, size: 20),
                    label: Text(_copied ? 'Copied' : 'Copy link'),
                  ),
                ),
              ],
            ),
        ],
        if (!waiting && theirs.containsKey(Shared.calendar))
          DenSection(
            title: 'Their calendar',
            child: events.isEmpty
                ? const EmptyState(compact: true, message: 'Nothing on it in the next two months.')
                : Column(
                    children: ruled([
                      for (final o in events)
                        NavRow(
                          icon: PhosphorIconsRegular.calendarBlank,
                          label: o.title,
                          detail: '${f.short(f.localDate(o.start))} · ${f.span(o.start, o.end, allDay: o.event.allDay)}',
                          onTap: () => context.push('/event/${o.event.id}?at=${o.start}'),
                        ),
                    ]),
                  ),
          ),
        if (!waiting && theirs.containsKey(Shared.calendar) && theirs[Shared.calendar] == ShareLevel.edit &&
            app.allows(DenAction.editEvents))
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => context.push('/event/new?date=${den.todayDate()}&link=${link.id}'),
              icon: const Icon(PhosphorIconsRegular.plus, size: 20),
              label: const Text('Add to their calendar'),
            ),
          ),
        if (!waiting && lists.isNotEmpty)
          DenSection(
            title: 'Their lists',
            child: Column(
              children: ruled([
                for (final l in lists)
                  NavRow(
                    icon: PhosphorIconsRegular.listChecks,
                    label: l.list.title,
                    value: den.seeOnlyList(l.list) ? 'To see' : null,
                    onTap: () => context.push('/lists/${l.list.id}'),
                  ),
              ]),
            ),
          ),
        if (!waiting && theirs.isEmpty)
          EmptyState(compact: true, message: '$who isn\'t sharing anything with you yet.'),
        if (parent) ...[
          DenSection(
            title: 'What you share with them',
            carded: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ShareLine(
                  label: 'Your calendar',
                  value: share[Shared.calendar],
                  options: _levels,
                  onChanged: (level) => _share(Shared.calendar, level),
                ),
                for (final l in mine)
                  _ShareLine(
                    label: l.list.title,
                    value: share[l.list.id],
                    options: _levels,
                    onChanged: (level) => _share(l.list.id, level),
                  ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
              child: Semantics(liveRegion: true, child: Text(_error!, style: t.meta(c.destructive))),
            ),
          if (!_ending)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _ending = true),
                style: TextButton.styleFrom(foregroundColor: c.destructive),
                child: const Text('End link'),
              ),
            ),
          DenReveal(
            visible: _ending,
            child: !_ending
                ? const SizedBox(width: double.infinity)
                : ConfirmPanel(
                    message: waiting
                        ? 'The link stops working.'
                        : 'Nothing is shared either way any more, and what they share leaves Den here.',
                    confirmLabel: 'End link',
                    destructive: true,
                    busy: _busy,
                    onConfirm: _end,
                    onCancel: () => setState(() => _ending = false),
                  ),
          ),
        ],
      ],
    );
  }
}

/// One thing this family may share: its name, then Off, See or Change.
class _ShareLine extends StatelessWidget {
  const _ShareLine({required this.label, required this.value, required this.options, required this.onChanged});

  final String label;
  final ShareLevel? value;
  final Map<ShareLevel?, String> options;
  final ValueChanged<ShareLevel?> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.s),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Sp.m,
        runSpacing: Sp.s,
        children: [
          Text(label, style: t.body(c.ink)),
          DenSegmented<ShareLevel?>(options: options, value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
