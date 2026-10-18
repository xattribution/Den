import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';
import 'package:den_core/time.dart';

/// A family member as capture sees them: enough to match a name someone wrote.
class CapturePerson {
  const CapturePerson({required this.id, required this.name, required this.role});
  final String id;
  final String name;
  final Role role;
}

/// A list items can go on.
class CaptureList {
  const CaptureList({required this.id, required this.title, required this.kind, required this.pinned});
  final String id;
  final String title;
  final ListKind kind;
  final bool pinned;
}

/// What a reader is told about the family and today, and what resolution matches against.
/// Built from the engine with [CaptureContext.of]; nothing in it leaves the device unless a
/// parent connected a reader that runs elsewhere.
class CaptureContext {
  const CaptureContext({
    required this.today,
    required this.timezone,
    required this.weekStart,
    required this.now,
    required this.people,
    this.actorId,
    this.lists = const [],
    this.stores = const [],
    this.categories = const {},
  });

  /// The family as the engine's acting member sees it.
  factory CaptureContext.of(Den den) {
    final family = den.family;
    return CaptureContext(
      today: den.todayDate(),
      timezone: family?.timezone ?? 'UTC',
      weekStart: family?.weekStart ?? 0,
      now: den.now(),
      actorId: den.actor?.id,
      people: [for (final m in den.members) CapturePerson(id: m.id, name: m.name, role: m.role)],
      lists: [
        for (final l in den.lists)
          CaptureList(id: l.list.id, title: l.list.title, kind: l.list.kind, pinned: l.list.pinned),
      ],
      stores: den.stores,
      categories: {for (final c in den.categories) c.icon: c.id},
    );
  }

  /// Local date, `YYYY-MM-DD`, in [timezone].
  final String today;
  final String timezone;

  /// 0 Sunday, 1 Monday.
  final int weekStart;

  /// UTC milliseconds.
  final int now;

  /// Who is sharing; "me" and "I" mean them.
  final String? actorId;
  final List<CapturePerson> people;
  final List<CaptureList> lists;
  final List<String> stores;

  /// Category pictogram key to the family's category with that icon.
  final Map<String, String> categories;

  CapturePerson? get actor => people.firstWhereOrNull((p) => p.id == actorId);

  /// The list groceries go on: the first pinned shopping list, else the first shopping list.
  CaptureList? get groceries {
    final shopping = lists.where((l) => l.kind == ListKind.shopping);
    return shopping.firstWhereOrNull((l) => l.pinned) ?? shopping.firstOrNull;
  }

  /// The member [name] refers to: their full name, their first name, a name that starts with
  /// it ("Grandma" for "Grandma Rosa"), or the person sharing for "me" and "I". Null when
  /// nobody, or more than one person, fits.
  CapturePerson? person(String name) {
    final n = _plain(name);
    if (n.isEmpty) return null;
    if (const {'me', 'i', 'myself', 'mine', 'my'}.contains(n)) return actor;
    final exact = people.where((p) => _plain(p.name) == n).toList();
    if (exact.length == 1) return exact.single;
    final first = people.where((p) => _plain(p.name).split(' ').first == n).toList();
    if (first.length == 1) return first.single;
    final words = people.where((p) => _plain(p.name).split(' ').contains(n)).toList();
    if (words.length == 1) return words.single;
    final prefix = people.where((p) => n.length >= 3 && _plain(p.name).startsWith(n)).toList();
    return prefix.length == 1 ? prefix.single : null;
  }

  /// The list a name refers to, matching titles loosely ("the packing list" finds "Beach trip
  /// packing", "groceries" finds the groceries list).
  CaptureList? list(String name) {
    final n = _plain(name).replaceAll(RegExp(r'\b(the|my|our|list)\b'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (n.isEmpty) return null;
    final exact = lists.firstWhereOrNull((l) => _plain(l.title) == n);
    if (exact != null) return exact;
    if (RegExp(r'^(grocer|shopping|food|supermarket)').hasMatch(n)) return groceries;
    final containing = lists.where((l) => _plain(l.title).contains(n) || n.contains(_plain(l.title))).toList();
    if (containing.length == 1) return containing.single;
    final kind = ListKind.values.firstWhereOrNull((k) => n == k.name || n == '${k.name}s');
    if (kind != null) return lists.firstWhereOrNull((l) => l.kind == kind);
    return null;
  }

  /// A store as the family already spells it, or [name] tidied.
  String store(String name) {
    final n = _plain(name);
    return stores.firstWhereOrNull((s) => _plain(s) == n) ?? name.trim();
  }

  /// "Friday, October 16, 2026".
  String get todayWords {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
      'November', 'December',
    ];
    final y = today.substring(0, 4), m = int.parse(today.substring(5, 7)), d = int.parse(today.substring(8, 10));
    return '${days[weekdayOf(today) - 1]}, ${months[m - 1]} $d, $y';
  }

  static String _plain(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r"['’]s\b"), '')
      .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
