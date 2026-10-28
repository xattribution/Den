import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/den_scope.dart';

/// The family's trust decisions: who is a parent, what a kid may do, how someone signs in on a
/// shared screen, whether parents see a kid's private items, and which devices are in the
/// family. No action offers these, on purpose: the engine takes them only from a parent on
/// their own device, never from a shared screen, the hub, MCP or an assistant. They are the
/// only family writes that go to the engine directly.
class TrustActions {
  const TrustActions(this._den);

  final Den _den;

  Future<void> setRole(String member, Role role, {Tier? tier}) =>
      _den.updateMember(member, {'role': role.name, 'tier': role == Role.kid ? tier?.name : null});

  Future<void> setGrants(String member, Set<Grant> grants) => _den.updateMember(member, {
        'grants': [
          for (final g in Grant.values)
            if (grants.contains(g)) g.name,
        ],
      });

  /// Just this person's entry, so two parents changing different people at once both count.
  Future<void> setParentsSeePrivate(String member, bool on) => _den.updateFamily({
        'oversight.$member': {'parentsSeePrivate': on},
      });

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
