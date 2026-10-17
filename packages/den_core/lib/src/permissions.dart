import 'model.dart';

/// Everything a person can be allowed or refused. See ARCHITECTURE.md, "Permissions".
enum DenAction {
  /// Family settings, members, devices, approving and revoking devices, subscriptions.
  manageFamily,
  editEvents,
  editChores,
  editLists,
  checkItems,

  /// Complete or check steps of a chore the person owns that day, or an "anyone" chore.
  completeOwnChore,

  /// Complete someone else's chore.
  completeAnyChore,

  /// Swap a chore they own for one day.
  swapChore,

  /// Adjust points, edit goals and rewards, decide redemptions.
  managePoints,

  /// Ask to spend their own points on a reward.
  requestReward,
}

/// Whether [member] may perform [action]. A null member is an anonymous actor on a shared
/// display with open check-off; it may only check items and complete chores, and only when
/// [openCheckoff] is true.
bool can(Member? member, DenAction action, {bool openCheckoff = false}) {
  if (member == null) {
    return openCheckoff &&
        (action == DenAction.checkItems ||
            action == DenAction.completeOwnChore ||
            action == DenAction.completeAnyChore);
  }
  final grants = member.grants;
  switch (member.role) {
    case Role.parent:
      return true;
    case Role.adult:
      return action != DenAction.manageFamily && action != DenAction.managePoints;
    case Role.kid:
      return switch (action) {
        DenAction.checkItems ||
        DenAction.completeOwnChore ||
        DenAction.swapChore ||
        DenAction.requestReward =>
          true,
        DenAction.editEvents => grants.contains(Grant.events),
        DenAction.editChores => grants.contains(Grant.chores),
        DenAction.editLists => grants.contains(Grant.lists),
        DenAction.managePoints => grants.contains(Grant.points),
        DenAction.completeAnyChore || DenAction.manageFamily => false,
      };
    case Role.guest:
      return action == DenAction.checkItems || action == DenAction.completeOwnChore;
  }
}

/// Whether [member] may read records in [space], given the family's oversight policy.
/// Shared displays read only the family space; hubs read everything (callers check device mode).
bool canRead(Member member, String space, Family? family) {
  if (space == Space.family) return true;
  if (space == Space.parents) return member.role == Role.parent;
  final owner = Space.memberOf(space);
  if (owner == null) return false;
  if (owner == member.id) return true;
  return member.role == Role.parent && (family?.parentsSeePrivate(owner) ?? true);
}

/// The spaces a device should hold, given its owner and mode.
Set<String> spacesFor({
  required Device device,
  required Member? owner,
  required Family? family,
  required Iterable<Member> members,
}) {
  if (device.mode == DeviceMode.hub) {
    return {Space.family, Space.parents, for (final m in members) Space.member(m.id)};
  }
  if (device.mode == DeviceMode.shared || owner == null) return {Space.family};
  return {
    Space.family,
    if (owner.role == Role.parent) Space.parents,
    for (final m in members)
      if (canRead(owner, Space.member(m.id), family)) Space.member(m.id),
  };
}
