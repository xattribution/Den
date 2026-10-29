import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/den_scope.dart';
import '../words/oversight.dart';

/// The family's trust decisions: who is a parent, what a kid may do, how someone signs in on a
/// shared screen, whether parents see a kid's private items, who may use the AI helper, and
/// which devices are in the family. No action offers these, on purpose: the engine takes them
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
        KidSwitch.lists || KidSwitch.plans || KidSwitch.rewardsOk => setGrants(kid.id, grantsWith(which, on, kid.grants)),
        KidSwitch.private => setParentsSeePrivate(kid.id, !on),
        KidSwitch.assistant => setAssistantFor(kid.id, on),
      };

  /// Just this person's entry, so two parents changing different people at once both count.
  Future<void> setParentsSeePrivate(String member, bool on) => _den.updateFamily({
        'oversight.$member': {'parentsSeePrivate': on},
      });

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

  /// [member]'s recovery key (the public half of what their 12 words stretch to), or null to
  /// take their words away. Only the parent themselves sets theirs (state/recovery.dart).
  Future<void> setRecoveryKey(String member, String? publicKey) => _den.setRecoveryKey(member, publicKey);

  /// "Let the hub help us get back in": the hub's server recovery key, or null to stop it.
  Future<void> setHubHelp(String? serverKey) => _den.setServerRecoveryKey(serverKey);
}

extension TrustActionsOf on BuildContext {
  /// The family's trust decisions, for a parent on their own device.
  TrustActions get trustActions => TrustActions(actions.den);
}
