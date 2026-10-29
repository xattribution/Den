import 'dart:convert';

import 'package:den_core/den_core.dart' show newId;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a log this device holds is: a family, or (later) a group of families.
enum MembershipKind { family, group }

/// One log this device holds an engine for: a family (and later a group). Each has its own
/// device keys, change log, change counter and sync settings, so nothing of one family's mixes
/// with another's on this device:
///
/// | | The first log ([primary]) | Every later one |
/// | --- | --- | --- |
/// | Change log (web) | IndexedDB database `den` | `den-<slot>` |
/// | Change log (phones, computers) | `<app support>/den/` | `<app support>/den-<slot>/` |
/// | Device keys (keychain) | `den.device.keys` | `den.device.keys.<slot>` |
/// | This device's settings for it (hubs, notices put away) | `den.hubs`, `den.seen`, ... | `den.hubs.<slot>`, `den.seen.<slot>`, ... |
/// | The hub this app can run for it ("Keep the family online") | `<app support>/hub/` | `<app support>/hub-<slot>/` |
///
/// The first log keeps the names Den always used, so a device in one family is never touched
/// by having this list, and has no list at all until it joins a second family. Every later log
/// is kept under a [slot] this device picked at random, never under anything a server said (a
/// family id): no answer can name a directory, and two names that differ only in case (one
/// directory on macOS and Windows) never come from outside.
@immutable
class Membership {
  const Membership({
    required this.id,
    this.kind = MembershipKind.family,
    this.hub,
    this.label,
    this.primary = false,
    this.color,
    this.slot,
  });

  /// The log's id: its family's id, as den_core makes them ([validId]).
  final String id;

  final MembershipKind kind;

  /// The origin of the hub it syncs with (`https://den.kotvas.app`), when known.
  final String? hub;

  /// The family's name when this device last saw it, for the switcher before its engine opens.
  final String? label;

  /// Kept under the names Den always used ([primaryStorage], [primaryKeys]): the first log this
  /// device held.
  final bool primary;

  /// Which of the eight color places the family's source tag takes on this device ("All my
  /// families"), by [Marker] name; null draws the tag in ink.
  final String? color;

  /// The name this device keeps a later log under: random, lowercase, its own ([newSlot]).
  /// Null for the first log.
  final String? slot;

  /// The first log's change log: IndexedDB database `den`, or the `den` directory.
  static const primaryStorage = 'den';

  /// The first log's device keys in the keychain.
  static const primaryKeys = 'den.device.keys';

  /// The first log's in-app hub data directory.
  static const primaryHub = 'hub';

  String get _name => slot ?? id;

  /// Its change log's name: [primaryStorage], or `den-<slot>`.
  String get storage => primary ? primaryStorage : '$primaryStorage-$_name';

  /// Its device keys' keychain item: [primaryKeys], or `den.device.keys.<slot>`.
  String get keys => primary ? primaryKeys : '$primaryKeys.$_name';

  /// The data directory of the hub this app runs for it: [primaryHub], or `hub-<slot>`.
  String get hubData => primary ? primaryHub : '$primaryHub-$_name';

  /// This device's setting [key] for this log: the key itself for the first log, `<key>.<slot>`
  /// for the others.
  String pref(String key) => primary ? key : '$key.$_name';

  static final RegExp _form = RegExp(r'^[a-z2-7]{16}$');
  static final RegExp _placeholder = RegExp(r'^[a-z0-9]{1,64}$');

  /// Whether [id] is a family id as den_core makes them: 16 lowercase base32 letters (80 bits of
  /// a hash). Anything else, an upper-case twin of a real id included, is refused.
  static bool validId(String id) => _form.hasMatch(id);

  /// Whether [slot] is one this device would have picked ([newSlot]).
  static bool validSlot(String slot) => _form.hasMatch(slot);

  /// A fresh random slot: 16 lowercase base32 letters.
  static String newSlot() => newId();

  /// Whether this log is kept under the same names as [other] (compared as a case-insensitive
  /// file system would).
  bool sharesStorageWith(Membership other) => storage.toLowerCase() == other.storage.toLowerCase();

  Membership copyWith({String? hub, String? label, String? color}) => Membership(
        id: id,
        kind: kind,
        hub: hub ?? this.hub,
        label: label ?? this.label,
        primary: primary,
        color: color ?? this.color,
        slot: slot,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'hub': ?hub,
        'label': ?label,
        if (primary) 'primary': true,
        'color': ?color,
        'slot': ?slot,
      };

  /// Reads a listed log; null when it isn't one this device could have written: a later log
  /// whose id isn't a family id ([validId]) or whose slot isn't one this device picks. (A later
  /// log listed before slots were kept is named by its id, which [validId] holds to lowercase.
  /// The first log's id names nothing, and is a placeholder until its family exists.)
  static Membership? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    String? text(String key) => json[key] is String ? json[key] as String : null;
    final primary = json['primary'] == true;
    if (id is! String || (primary ? !_placeholder.hasMatch(id) : !validId(id))) return null;
    final slot = text('slot');
    if (!primary && slot != null && !validSlot(slot)) return null;
    return Membership(
      id: id,
      kind: MembershipKind.values.asNameMap()[json['kind']] ?? MembershipKind.family,
      hub: text('hub'),
      label: text('label'),
      primary: primary,
      color: text('color'),
      slot: primary ? null : slot,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Membership &&
      other.id == id &&
      other.kind == kind &&
      other.hub == hub &&
      other.label == label &&
      other.primary == primary &&
      other.color == color &&
      other.slot == slot;

  @override
  int get hashCode => Object.hash(id, kind, hub, label, primary, color, slot);

  @override
  String toString() => 'Membership($id${primary ? ', primary' : ', $slot'}${label == null ? '' : ', $label'})';
}

/// The logs this device holds ([key], `den.memberships`) and which one it shows ([activeKey]).
/// A device in one family has neither: the list is written when a second family joins, and
/// stays, so the device knows which names are whose from then on.
abstract final class Memberships {
  /// The list, as JSON: `[{id, kind, hub, label, primary, color, slot}]`.
  static const key = 'den.memberships';

  /// What the device shows: a log's id, or [all].
  static const activeKey = 'den.household.active';

  /// "All my families".
  static const all = 'all';

  /// The list; empty on a device that never held a second family. One entry per family, one
  /// first log, and never two kept under the same names.
  static Future<List<Membership>> load() async {
    try {
      final text = (await SharedPreferences.getInstance()).getString(key);
      if (text == null) return const [];
      final json = jsonDecode(text);
      if (json is! List) return const [];
      final out = <Membership>[];
      for (final item in json) {
        final m = Membership.fromJson(item);
        if (m == null || out.any((o) => o.id == m.id || (o.primary && m.primary) || o.sharesStorageWith(m))) continue;
        out.add(m);
      }
      return out;
    } on Object {
      return const [];
    }
  }

  static Future<void> save(List<Membership> logs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode([for (final m in logs) m.toJson()]));
  }

  static Future<String?> loadActive() async {
    try {
      return (await SharedPreferences.getInstance()).getString(activeKey);
    } on Object {
      return null;
    }
  }

  static Future<void> saveActive(String? choice) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (choice == null) {
        await prefs.remove(activeKey);
      } else {
        await prefs.setString(activeKey, choice);
      }
    } on Object {
      // Only which family opens first.
    }
  }
}
