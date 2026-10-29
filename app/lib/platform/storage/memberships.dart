import 'dart:convert';

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
/// | Change log (web) | IndexedDB database `den` | `den-<id>` |
/// | Change log (phones, computers) | `<app support>/den/` | `<app support>/den-<id>/` |
/// | Device keys (keychain) | `den.device.keys` | `den.device.keys.<id>` |
/// | This device's settings for it (hubs, notices put away) | `den.hubs`, `den.seen`, ... | `den.hubs.<id>`, `den.seen.<id>`, ... |
///
/// The first log keeps the names Den always used, so a device in one family is never touched
/// by having this list, and has no list at all until it joins a second family.
@immutable
class Membership {
  const Membership({required this.id, this.kind = MembershipKind.family, this.hub, this.label, this.primary = false, this.color});

  /// The log's id: its family's id.
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

  /// The first log's change log: IndexedDB database `den`, or the `den` directory.
  static const primaryStorage = 'den';

  /// The first log's device keys in the keychain.
  static const primaryKeys = 'den.device.keys';

  /// Its change log's name: [primaryStorage], or `den-<id>`.
  String get storage => primary ? primaryStorage : '$primaryStorage-$id';

  /// Its device keys' keychain item: [primaryKeys], or `den.device.keys.<id>`.
  String get keys => primary ? primaryKeys : '$primaryKeys.$id';

  /// This device's setting [key] for this log: the key itself for the first log, `<key>.<id>`
  /// for the others.
  String pref(String key) => primary ? key : '$key.$id';

  /// Whether [id] can name a log's storage: letters, digits, `-` and `_`, 1 to 64 (a family id
  /// is 16 lowercase base32 letters).
  static bool validId(String id) => RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id);

  Membership copyWith({String? hub, String? label, String? color}) => Membership(
        id: id,
        kind: kind,
        hub: hub ?? this.hub,
        label: label ?? this.label,
        primary: primary,
        color: color ?? this.color,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'hub': ?hub,
        'label': ?label,
        if (primary) 'primary': true,
        'color': ?color,
      };

  static Membership? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || !validId(id)) return null;
    String? text(String key) => json[key] is String ? json[key] as String : null;
    return Membership(
      id: id,
      kind: MembershipKind.values.asNameMap()[json['kind']] ?? MembershipKind.family,
      hub: text('hub'),
      label: text('label'),
      primary: json['primary'] == true,
      color: text('color'),
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
      other.color == color;

  @override
  int get hashCode => Object.hash(id, kind, hub, label, primary, color);

  @override
  String toString() => 'Membership($id${primary ? ', primary' : ''}${label == null ? '' : ', $label'})';
}

/// The logs this device holds ([key], `den.memberships`) and which one it shows ([activeKey]).
/// A device in one family has neither: the list is written when a second family joins, and
/// stays, so the device knows which names are whose from then on.
abstract final class Memberships {
  /// The list, as JSON: `[{id, kind, hub, label, primary, color}]`.
  static const key = 'den.memberships';

  /// What the device shows: a log's id, or [all].
  static const activeKey = 'den.household.active';

  /// "All my families".
  static const all = 'all';

  /// The list; empty on a device that never held a second family.
  static Future<List<Membership>> load() async {
    try {
      final text = (await SharedPreferences.getInstance()).getString(key);
      if (text == null) return const [];
      final json = jsonDecode(text);
      if (json is! List) return const [];
      final out = <Membership>[];
      for (final item in json) {
        final m = Membership.fromJson(item);
        // One engine per log, and one first log.
        if (m == null || out.any((o) => o.id == m.id || (o.primary && m.primary))) continue;
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
