import 'package:den_core/den_core.dart';

import '../../../app/family_reads.dart';

/// "14 items, 5 at Costco, 3 at Target", "All done", "No items".
String listSummary(ListState lv, {int stores = 2}) {
  final total = lv.items.length;
  if (total == 0) return 'No items';
  final open = lv.open;
  if (open == 0) return 'All done';
  final parts = ['$open ${open == 1 ? 'item' : 'items'}'];
  if (lv.list.kind == ListKind.shopping) {
    final byStore = lv.openByStore.entries.where((e) => e.key.isNotEmpty).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in byStore.take(stores)) {
      parts.add('${e.value} at ${e.key}');
    }
  }
  return parts.join(', ');
}

/// When a list is for: "Need by Fri, Oct 23", "For Soccer tournament, Sat, Oct 24", or null for
/// running lists. [late] is true when a dated list's day has passed with items still open.
({String text, bool late})? listTiming(FamilyReads app, ListState lv) {
  final list = lv.list;
  final f = app.formats;
  switch (list.lifecycle) {
    case ListLifecycle.running:
      return null;
    case ListLifecycle.dated:
      final needBy = list.needBy;
      if (needBy == null) return null;
      final late = needBy.compareTo(app.today) < 0 && lv.open > 0;
      final when = f.relative(needBy, app.today);
      return (
        text: late
            ? 'Late, needed by $when'
            : 'Need by ${when == 'Today' || when == 'Tomorrow' ? when.toLowerCase() : when}',
        late: late,
      );
    case ListLifecycle.event:
      final id = list.event;
      final event = id == null ? null : app.den.event(id);
      if (event == null) return (text: 'For an event that was removed', late: false);
      return (text: 'For ${event.title}, ${f.relative(f.localDate(event.start), app.today)}', late: false);
  }
}

/// One thing to put on a list, as typed into the add field.
typedef NewItem = ({String text, String? qty, String? store});

final RegExp _leadingQty = RegExp(
  r'^(\d+(?:[.,]\d+)?(?:\s*/\s*\d+)?|a dozen|a couple of|½|¼)\s*'
  r'(x|gal|gallons?|lbs?|pounds?|oz|ounces?|kg|g|l|ml|dozen|doz|packs?|bags?|boxes|box|bottles?|cans?|jars?|bunch(?:es)?|cartons?|loaf|loaves)?\b\s*',
  caseSensitive: false,
);
final RegExp _trailingTimes = RegExp(r'\s+x\s*(\d+)$', caseSensitive: false);
final RegExp _store = RegExp(r'\s*@\s*([^@]+)$');

/// Reads the add field: commas separate things, a number (and a unit) up front is the quantity,
/// "x2" at the end too, and "@Costco" at the end of one is its store, matched to a store the
/// family already uses whatever its case. "2 milk @Costco, eggs" is two items.
List<NewItem> parseItems(String input, {List<String> knownStores = const []}) {
  final out = <NewItem>[];
  for (final raw in input.split(RegExp(r'[,\n;]'))) {
    var text = raw.trim();
    if (text.isEmpty) continue;
    String? store;
    final at = _store.firstMatch(text);
    if (at != null) {
      final named = at.group(1)!.trim();
      store = knownStores.firstWhere((s) => s.toLowerCase() == named.toLowerCase(), orElse: () => named);
      text = text.substring(0, at.start).trim();
    }
    String? qty;
    final lead = _leadingQty.firstMatch(text);
    if (lead != null && lead.end < text.length) {
      final n = lead.group(1)!;
      final unit = lead.group(2);
      qty = unit == null || unit.toLowerCase() == 'x' ? n : '$n $unit';
      text = text.substring(lead.end).trim();
    } else if (_trailingTimes.firstMatch(text) case final m?) {
      qty = m.group(1);
      text = text.substring(0, m.start).trim();
    }
    if (text.isEmpty) continue;
    out.add((text: '${text[0].toUpperCase()}${text.substring(1)}', qty: qty, store: store));
  }
  return out;
}

/// "Milk", "Milk and Eggs", "Milk, Eggs and 2 more".
String itemNames(List<NewItem> items) {
  final names = [for (final i in items) i.text];
  return switch (names.length) {
    0 => 'nothing',
    1 => names.single,
    2 => '${names[0]} and ${names[1]}',
    3 => '${names[0]}, ${names[1]} and ${names[2]}',
    _ => '${names[0]}, ${names[1]} and ${names.length - 2} more',
  };
}

/// Words for a list kind.
String kindWords(ListKind kind) => switch (kind) {
  ListKind.shopping => 'Shopping',
  ListKind.checklist => 'Checklist',
  ListKind.packing => 'Packing',
  ListKind.meal => 'Meals',
};

/// The first pinned shopping list, else the first shopping list: where groceries go.
ListState? groceriesList(Den den) {
  final shopping = den.lists.where((l) => l.list.kind == ListKind.shopping).toList();
  return shopping.where((l) => l.list.pinned).firstOrNull ?? shopping.firstOrNull;
}

/// Open items as plain text, grouped by store on shopping lists:
///
/// ```
/// Groceries
///
/// Costco
/// - Milk, 2
/// ```
String shareText(ListState lv) {
  final open = lv.items.where((i) => !i.checked).toList();
  final out = StringBuffer(lv.list.title);
  String line(Item i) => '- ${i.text}${i.qty == null || i.qty!.isEmpty ? '' : ', ${i.qty}'}';
  final stores = open.map((i) => i.store ?? '').toSet();
  if (lv.list.kind == ListKind.shopping && stores.any((s) => s.isNotEmpty)) {
    final ordered = stores.where((s) => s.isNotEmpty).toList()..sort();
    if (stores.contains('')) ordered.add('');
    for (final s in ordered) {
      out
        ..writeln()
        ..writeln()
        ..write(s.isEmpty ? 'Anywhere' : s);
      for (final i in open.where((i) => (i.store ?? '') == s)) {
        out
          ..writeln()
          ..write(line(i));
      }
    }
  } else {
    out.writeln();
    for (final i in open) {
      out
        ..writeln()
        ..write(line(i));
    }
  }
  return out.toString();
}
