import 'package:den_core/den_core.dart';

import 'format.dart';
import 'words.dart';

/// What screens, words and actions read about the family on this device, without Flutter, so
/// words stay plain Dart. [AppState] mixes it in.
mixin FamilyReads {
  /// This device's engine.
  Den get den;

  /// Dates and times in the family's zone.
  Formats get formats;

  String get today => den.todayDate();

  Member? get me => den.actor ?? den.owner;

  Member? memberById(String? id) => id == null ? null : den.member(id);

  /// Who sees something kept in [space], in words ("Just you", "Parents").
  String seenBy(String space) => audienceWords(space, me: me?.id, nameOf: (id) => memberById(id)?.name);

  List<Marker> markersFor(List<String> memberIds) {
    if (memberIds.isEmpty) return den.members.map((m) => m.marker).toList();
    return memberIds.map(den.member).whereType<Member>().map((m) => m.marker).toList();
  }

  /// Whether whoever is acting on this device may do [action]; used to hide what they can't.
  bool allows(DenAction action) {
    final actor = den.actor;
    if (actor != null) return can(actor, action);
    final device = den.thisDevice;
    return (device?.isShared ?? false) && can(null, action, openCheckoff: device?.openCheckoff ?? false);
  }

  /// Like [allows], for the family's trust decisions: approving, declining or removing devices,
  /// someone's role, permissions or sign-in, removing people, oversight. The engine takes those
  /// only from a parent's own device (or a hub its owner is using), never from a shared screen.
  bool allowsTrust(DenAction action) {
    final device = den.thisDevice;
    final actor = den.actor;
    if (device == null || actor == null) return false;
    final own = switch (device.mode) {
      DeviceMode.personal => true,
      DeviceMode.hub => device.member == actor.id,
      DeviceMode.shared => false,
    };
    return own && can(actor, action);
  }

  /// Whether whoever is acting may add, change or remove list items. The engine allows that to
  /// whoever may edit lists, whoever added the item; checking an item off is
  /// [DenAction.checkItems]. Every add-item and edit-item control asks this.
  bool get canChangeItems => allows(DenAction.editLists);
}
