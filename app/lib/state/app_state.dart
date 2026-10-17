import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import 'format.dart';

enum ThemeChoice { auto, day, night }

/// The app's live state: the device's [Den] engine plus UI preferences. Rebuilds listeners on
/// every change the engine applies, whether made here or synced from another device.
class AppState extends ChangeNotifier {
  AppState(this.den, {this.wall = false}) {
    _sub = den.onChange.listen((_) {
      _formats = null;
      notifyListeners();
    });
  }

  final Den den;

  /// Running as a shared wall display: larger type, the week grid first, "who's doing this?".
  bool wall;

  ThemeChoice _theme = ThemeChoice.auto;
  ThemeChoice get theme => _theme;
  set theme(ThemeChoice value) {
    _theme = value;
    notifyListeners();
  }

  StreamSubscription<Set<String>>? _sub;
  Formats? _formats;

  Formats get formats => _formats ??= Formats(den.family?.timezone ?? 'UTC');

  String get today => den.todayDate();

  Member? get me => den.actor ?? den.owner;

  Member? memberById(String? id) => id == null ? null : den.member(id);

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

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// Makes [AppState] available below it and rebuilds dependents when it changes.
class DenScope extends InheritedNotifier<AppState> {
  const DenScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DenScope>()!.notifier!;

  static AppState read(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<DenScope>()!.widget as DenScope).notifier!;
}

extension DenContext on BuildContext {
  AppState get app => DenScope.of(this);
  Den get den => DenScope.of(this).den;
}
