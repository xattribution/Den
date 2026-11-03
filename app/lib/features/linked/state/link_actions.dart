import 'package:den_core/den_core.dart';

/// What a parent decides about linked families (a trust decision, made on their own phone: no
/// action offers it), and an event added to a linked family's calendar.
class LinkActions {
  const LinkActions(this.den);

  final Den den;

  /// A new link, or, with [id], one the other family's parent sent, being accepted here.
  Future<String> add({String? id}) => den.addFamilyLink(id: id);

  /// Shares [what] ([Shared.calendar] or a list's id) with link [id]'s family at [level], or
  /// stops (null).
  Future<void> share(String id, String what, ShareLevel? level) => den.shareWithFamily(id, what, level);

  Future<void> end(String id) => den.endFamilyLink(id);

  /// An event on link [link]'s family's calendar, which they let this family change: theirs
  /// once their hub has it, so no person or ride of this family goes with it.
  Future<String> addEvent({
    required String link,
    required String title,
    required int start,
    required int end,
    bool allDay = false,
    String? tz,
    String? rrule,
    String location = '',
    String notes = '',
    List<int> reminders = const [],
  }) =>
      den.addEvent(
        title: title,
        start: start,
        end: end,
        allDay: allDay,
        tz: tz,
        rrule: rrule,
        location: location,
        notes: notes,
        reminders: reminders,
        link: link,
      );
}
