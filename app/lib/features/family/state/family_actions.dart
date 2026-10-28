import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/actions.dart';
import '../../../app/den_scope.dart';

const List<String> _weekdays = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];

/// The family's settings and people, each change a den_actions action. Roles, permissions,
/// sign-in, oversight and devices are trust decisions with no action on purpose: those are in
/// trust_actions.dart.
class FamilyActions {
  const FamilyActions(this._actions);

  final AppActions _actions;

  Future<ActionResult> _settings(Map<String, Object?> args) => _actions.run('update_family_settings', args);

  Future<ActionResult> rename(String name) => _settings({'name': name});

  Future<ActionResult> setTimeZone(String zone) => _settings({'timezone': zone});

  /// [day] is 0 for Sunday to 6 for Saturday.
  Future<ActionResult> setWeekStart(int day) => _settings({'week_start': _weekdays[day]});

  /// Whether what Den reads from photos and messages waits for a look first.
  Future<ActionResult> setCaptureReview(bool review) => _settings({'capture': review ? 'review' : 'direct'});

  /// Adds someone. A kid's [tier] counts only for a kid; their own permissions ([Grant]s) are a
  /// trust decision, given after with [TrustActions.setGrants].
  Future<ActionResult> addPerson({
    required String name,
    required Role role,
    Tier? tier,
    Marker? marker,
    String? picture,
    String? birthday,
  }) =>
      _actions.run('save_member', {
        'name': name,
        'role': role.name,
        if (role == Role.kid && tier != null) 'tier': tier.name,
        'color': marker?.name,
        'picture': picture,
        'birthday': birthday,
      });

  /// Changes someone's details: whatever is given (an empty [birthday] clears it).
  Future<ActionResult> saveDetails(
    String member, {
    String? name,
    Tier? tier,
    Marker? marker,
    String? picture,
    String? birthday,
  }) =>
      _actions.run('save_member', {
        'member': member,
        'name': name,
        'tier': tier?.name,
        'color': marker?.name,
        'picture': picture,
        'birthday': birthday,
      });
}

extension FamilyActionsOf on BuildContext {
  /// The family's actions. Reading them never rebuilds.
  FamilyActions get familyActions => FamilyActions(actions);
}
