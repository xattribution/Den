import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/family_reads.dart';

/// Where a calendar's events come from. Today: the family's own calendar, each calendar it
/// subscribes to, and the phone's own calendars. Later: each group shared with other families,
/// and calendars other families share.
enum CalendarSourceKind { family, subscription, phone, group }

/// A calendar source, with its color as data of its own, apart from people's colors (DESIGN.md,
/// "What may carry color"): a source's color only ever shows on its small tag (its initial in a
/// rounded square) and on the outline of its events, and never takes the place of a person's
/// color on a block, a dot or a day. Nothing draws source tags yet; this is the model they read.
@immutable
class CalendarSource {
  const CalendarSource({required this.kind, required this.id, required this.label, this.color});

  final CalendarSourceKind kind;

  /// The family's id, a subscription's id, `phone`, or a group's id.
  final String id;

  /// What the tag and its filter chip say: "Kotvas", "Oak Grove School".
  final String label;

  /// One of the eight places of the family's colors, drawn in the family's pack like a person's
  /// (`context.colors.marker`) but meaning the source; null until someone picks one, and then
  /// the source has no color and its tag is ink.
  final Marker? color;

  /// The letter on its tag.
  String get initial => label.trim().isEmpty ? '' : label.trim().characters.first.toUpperCase();

  @override
  bool operator ==(Object other) => other is CalendarSource && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// The sources the family's calendar holds now: its own, then each calendar it subscribes to.
/// A subscription's color is read from its record (`subscription.color`) once the schema has it.
List<CalendarSource> calendarSources(FamilyReads app) {
  final family = app.den.family;
  return [
    CalendarSource(kind: CalendarSourceKind.family, id: family?.id ?? '', label: family?.name ?? ''),
    for (final s in app.den.subscriptions)
      CalendarSource(
        kind: CalendarSourceKind.subscription,
        id: s.id,
        label: s.label,
        color: Marker.parse(s.rec.fields['color']),
      ),
  ];
}

/// The source [occ] comes from: an imported event names its calendar by label; one from the
/// phone is the phone's; anything else is the family's own.
CalendarSource sourceOf(FamilyReads app, Occurrence occ) {
  final source = occ.event.source;
  final sources = calendarSources(app);
  switch (source.kind) {
    case 'ics':
      for (final s in sources) {
        if (s.kind == CalendarSourceKind.subscription && s.label == source.label) return s;
      }
      return CalendarSource(kind: CalendarSourceKind.subscription, id: source.label ?? '', label: source.label ?? '');
    case 'device':
      return CalendarSource(kind: CalendarSourceKind.phone, id: 'phone', label: source.label ?? 'This phone');
    default:
      return sources.first;
  }
}
