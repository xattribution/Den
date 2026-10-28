import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../state/calendar_models.dart';
import '../state/day_groups.dart';
import '../words/block_words.dart';
import 'combine_stack.dart';
import 'event_block.dart';

/// Whether [occ] belongs in a list narrowed to [person] (null: everyone's): theirs, or the
/// family's.
bool showsFor(Occurrence occ, String? person) =>
    person == null || occ.assignees.isEmpty || occ.assignees.contains(person);

/// Opens an occurrence's page from the calendar.
void openEvent(BuildContext context, Occurrence occ) =>
    context.push('/event/${occ.event.id}?at=${occ.start}&from=calendar');

/// Which groups the person combined, by [DayGroup.key]. Kept by the calendar while it's open.
class Combined extends ChangeNotifier {
  final Set<String> _keys = {};

  bool contains(String key) => _keys.contains(key);

  void toggle(String key) {
    if (!_keys.remove(key)) _keys.add(key);
    notifyListeners();
  }
}

/// One day of the calendar as a list: its heading ("Today, Wednesday"), then its events as solid
/// blocks by time. Events at the same time stack together and can be combined into one block
/// that opens again on a tap. A day with nothing planned says so, with the way to add something.
class DaySection extends StatelessWidget {
  const DaySection({
    super.key,
    required this.date,
    required this.occurrences,
    required this.combined,
    this.person,
    this.emptyAction = true,
  });

  final String date;

  /// The day's events, already narrowed to [person] and sorted for the day.
  final List<Occurrence> occurrences;
  final Combined combined;
  final String? person;

  /// Offers "Add event" on an empty day.
  final bool emptyAction;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final f = app.formats;
    final c = context.colors;
    final heading = dayHeading(f, date, app.today);
    final groups = groupDay(occurrences, f, date);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
          child: Semantics(header: true, child: Text(heading, style: context.text.section(c.ink))),
        ),
        const SizedBox(height: DenLayout.headingGap),
        if (groups.isEmpty)
          _EmptyDay(date: date, person: person, action: emptyAction)
        else
          ListenableBuilder(
            listenable: combined,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, group) in groups.indexed) ...[
                  if (i > 0) const SizedBox(height: 10),
                  GroupRow(
                    group: group,
                    person: person,
                    combined: combined.contains(group.key),
                    onToggle: () => combined.toggle(group.key),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// A time and the events that start then: one block, or a stack of them with "Combine 2" under
/// it, or one combined block with "Show both". Past 135 % text the time moves above the blocks
/// so the titles keep their room.
class GroupRow extends StatelessWidget {
  const GroupRow({super.key, required this.group, required this.combined, required this.onToggle, this.person});

  final DayGroup group;
  final bool combined;
  final VoidCallback onToggle;

  /// The person the list is narrowed to, whose color their events take.
  final String? person;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final items = group.items;
    final above = MediaQuery.textScalerOf(context).scale(1) > 1.35;
    final timeText = group.time ?? 'All day';
    bool heroDay(Occurrence occ) => DenScope.read(context).formats.localDate(occ.start) == group.date;

    Widget blocks;
    if (!group.isMulti) {
      final occ = items.single;
      blocks = EventBlock(
        occ: occ,
        date: group.date,
        person: person,
        hero: heroDay(occ),
        onTap: () => openEvent(context, occ),
      );
    } else {
      blocks = CombineStack(
        combined: combined,
        blocks: [
          for (final (i, occ) in items.indexed)
            EventBlock(
              person: person,
              occ: occ,
              date: group.date,
              position: BlockPosition.at(i, items.length),
              hero: heroDay(occ),
              onTap: () => openEvent(context, occ),
            ),
        ],
        merged: MergedBlock(items: items, date: group.date, onTap: onToggle),
      );
    }

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        blocks,
        if (group.isMulti)
          Semantics(
            button: true,
            label: combined ? _showLabel(items.length) : 'Combine ${items.length} events at $timeText',
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: Targets.adult),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: 1,
                    child: Text(
                      combined ? _showLabel(items.length) : 'Combine ${items.length}',
                      style: t.meta(c.ink2).bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    final time = Text(keepUnits(timeText), style: t.meta(c.ink2), maxLines: 1, softWrap: false);
    if (above) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 6), child: time),
          column,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: timeColumnWidth(context),
          child: Padding(
            padding: EdgeInsets.only(top: group.isMulti ? 13 : 15),
            child: time,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: column),
      ],
    );
  }

  static String _showLabel(int n) => n == 2 ? 'Show both' : 'Show all $n';
}

class _EmptyDay extends StatelessWidget {
  const _EmptyDay({required this.date, required this.person, required this.action});

  final String date;
  final String? person;
  final bool action;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(calendarReads);
    final c = context.colors;
    final who = person == null ? 'anyone' : (app.memberById(person)?.name ?? 'them');
    final canAdd = action && app.allows(DenAction.editEvents);
    // The shared empty state, in the card where the day's blocks would be.
    return DecoratedBox(
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(Radii.block)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.l),
        child: EmptyState(
          compact: true,
          message: 'Nothing on the calendar for $who.',
          actionLabel: canAdd ? 'Add event' : null,
          onAction: canAdd ? () => context.push('/event/new?date=$date${person == null ? '' : '&who=$person'}') : null,
        ),
      ),
    );
  }
}
