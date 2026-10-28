import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/family_reads.dart';
import '../../../design/pictograms.dart';
import '../../../design/tokens.dart';
import '../words/block_words.dart';
import '../words/event_kinds.dart';

/// How an event looks wherever it's drawn: a solid block in its first person's color with dark
/// ink on it, or, for everyone, a solid ink block with the family's dots; the pictogram of its
/// kind; who else is in it. Never a tint, a stripe or a wash (ANTI-SLOP 3 and 7).
class EventLook {
  const EventLook({
    required this.fill,
    required this.ink,
    required this.everyone,
    required this.people,
    required this.family,
    required this.icon,
    required this.who,
  });

  /// The block's color: the first person's, or ink for everyone.
  final Color fill;

  /// Text and pictogram on [fill]: `onMarker` (#141414) on a person, `onPrimary` on ink.
  final Color ink;

  /// For the whole family: nobody named, or everyone named.
  final bool everyone;

  /// Who it's for, in the order the event names them; empty for everyone.
  final List<Member> people;

  /// The family, for everyone's dots.
  final List<Member> family;
  final IconData icon;

  /// "Leo and Mia", or "Everyone".
  final String who;

  Member? get lead => people.isEmpty ? null : people.first;

  /// The faces beside the title: everyone but the person whose color the block is.
  List<Member> get others => people.length <= 1 ? const [] : people.sublist(1);

  /// [column] is the person whose column the block sits in (the family week, the iPad day):
  /// there the block takes their color, as the paper organizer's columns do.
  static EventLook of(FamilyReads app, Occurrence occ, DenColors c, {Member? column}) {
    final family = app.den.members;
    final named = [for (final id in occ.assignees) ?app.memberById(id)];
    final everyone = named.isEmpty || (family.length > 1 && family.every((m) => occ.assignees.contains(m.id)));
    var people = everyone ? const <Member>[] : named;
    if (!everyone && column != null && people.any((m) => m.id == column.id)) {
      people = [
        column,
        for (final m in people)
          if (m.id != column.id) m,
      ];
    }
    final category = occ.category ?? occ.event.category;
    final kind = eventKind(
      occ.title,
      location: occ.location,
      category: category == null ? null : app.den.category(category)?.icon,
    );
    return EventLook(
      fill: everyone ? c.primary : c.marker(people.first.marker),
      ink: everyone ? c.onPrimary : c.onMarker,
      everyone: everyone,
      people: people,
      family: family,
      icon: Pictograms.event(kind),
      who: whoLine(people, everyone: everyone),
    );
  }
}
