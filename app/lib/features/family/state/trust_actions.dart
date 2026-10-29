import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/den_scope.dart';
import '../words/oversight.dart';

/// The family's trust decisions: who is a parent, what a kid may do, how someone signs in on a
/// shared screen, whether parents see a kid's private items, who may use the AI helper, until
/// when a sitter has Den, and which devices are in the family. No action offers these, on purpose: the engine takes them
/// only from a parent on their own device, never from a shared screen, the hub, MCP or an
/// assistant. They are the only family writes that go to the engine directly.
class TrustActions {
  const TrustActions(this._den);

  final Den _den;

  /// Makes [member] a [role]; a kid also gets [tier], and [grants] when given (a role change to
  /// kid starts from the age group's switches).
  Future<void> setRole(String member, Role role, {Tier? tier, Set<Grant>? grants}) => _den.updateMember(member, {
        'role': role.name,
        'tier': role == Role.kid ? tier?.name : null,
        if (grants != null) 'grants': _names(role == Role.kid ? grants : const {}),
      });

  Future<void> setGrants(String member, Set<Grant> grants) => _den.updateMember(member, {'grants': _names(grants)});

  static List<String> _names(Set<Grant> grants) => [
        for (final g in Grant.values)
          if (grants.contains(g)) g.name,
      ];

  /// One of a kid's switches ([KidSwitch]), whichever part of the family it lives in.
  Future<void> setKidSwitch(Member kid, KidSwitch which, bool on) => switch (which) {
        KidSwitch.lists || KidSwitch.plans => setGrants(kid.id, grantsWith(which, on, kid.grants)),
        KidSwitch.rewardsOk => _setRewardsOk(kid, on),
        KidSwitch.private => setParentsSeePrivate(kid.id, !on),
        KidSwitch.ownPicture => _setSetting(kid.id, OversightSetting.ownPicture, on),
        KidSwitch.assistant => setAssistantFor(kid.id, on),
      };

  /// On: their requests wait for a parent, and they give nobody stars. Off: they trade their
  /// own stars for rewards without asking.
  Future<void> _setRewardsOk(Member kid, bool on) async {
    if (on && kid.grants.contains(Grant.points)) await setGrants(kid.id, grantsWith(KidSwitch.rewardsOk, true, kid.grants));
    await _setSetting(kid.id, OversightSetting.rewardsNeedOk, on);
  }

  /// One setting of one person (`oversight.<id>.<setting>`), so parents changing different
  /// settings at once both count.
  Future<void> _setSetting(String member, String setting, bool on) => _den.updateFamily({'oversight.$member.$setting': on});

  /// Just this person's entry, so two parents changing different people at once both count.
  Future<void> setParentsSeePrivate(String member, bool on) => _den.updateFamily({
        'oversight.$member': {'parentsSeePrivate': on},
      });

  /// A sitter's last day (a local date), or null for no end.
  Future<void> setUntil(String member, String? until) => _den.updateMember(member, {'until': until});

  /// Ends a sitter's access now: yesterday becomes their last day and their devices are removed.
  Future<void> endAccessNow(String member) => _den.endAccessNow(member);

  /// Removes the devices of sitters whose last day has passed; this device's job whenever Den
  /// is open on a parent's own device. Returns whose.
  Future<List<String>> endExpiredAccess() => _den.endExpiredAccess();

  /// The family's rules for the AI helper (`family.assistant`).
  Future<void> setAssistant(AssistantPolicy policy) => _den.updateFamily({'assistant': policy.toJson()});

  /// Lets [member] use the AI helper, or not.
  Future<void> setAssistantFor(String member, bool on) {
    final policy = _den.family?.assistant ?? const AssistantPolicy();
    final members = {...policy.members};
    on ? members.add(member) : members.remove(member);
    return setAssistant(AssistantPolicy(
      enabled: policy.enabled,
      members: members,
      kidDailyLimit: policy.kidDailyLimit,
      budgetCents: policy.budgetCents,
    ));
  }

  Future<void> removePerson(String member) => _den.removeMember(member);

  /// `none`, or a PIN or picture pattern with its [secret].
  Future<void> setSignIn(String member, String kind, {String? secret}) =>
      _den.setSignIn(member, kind: kind, secret: secret);

  Future<void> approveDevice(String device, {String? member, required DeviceMode mode}) =>
      _den.approveDevice(device, member: member, mode: mode);

  Future<void> revokeDevice(String device) => _den.revokeDevice(device);

  Future<void> renameDevice(String device, String name) => _den.updateDevice(device, {'name': name});

  /// What a shared display shows ([display] is its whole settings map).
  Future<void> setDisplay(String device, Map<String, Object?> display) => _den.updateDevice(device, {'display': display});
}

extension TrustActionsOf on BuildContext {
  /// The family's trust decisions, for a parent on their own device.
  TrustActions get trustActions => TrustActions(actions.den);
}
