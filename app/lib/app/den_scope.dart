import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import 'app_state.dart';

/// Makes [AppState] available below it. A widget that reads it with [DenContext.watch] (or
/// [DenContext.view]) rebuilds only when a record type it named changes; one that uses
/// [DenContext.app] rebuilds on every change. Nothing else rebuilds: a checked grocery item
/// redraws the list it's on, not Today's events or the calendar kept alive in another tab.
class DenScope extends StatefulWidget {
  const DenScope({super.key, required this.state, required this.child});

  final AppState state;
  final Widget child;

  /// The state, rebuilding [context] on every change.
  static AppState of(BuildContext context) => InheritedModel.inheritFrom<_DenModel>(context)!.state;

  /// The state, rebuilding [context] only when one of [types] changes.
  static AppState watch(BuildContext context, Iterable<String> types) {
    _DenModel? model;
    for (final t in types) {
      model = InheritedModel.inheritFrom<_DenModel>(context, aspect: t);
    }
    return model?.state ?? read(context);
  }

  /// The state without rebuilding [context]: for callbacks.
  static AppState read(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<_DenModel>()!.widget as _DenModel).state;

  @override
  State<DenScope> createState() => _DenScopeState();
}

class _DenScopeState extends State<DenScope> {
  int _version = 0;

  /// Everything changes touched since the last build: several can land before a frame.
  Set<String> _touched = {};

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_changed);
  }

  @override
  void didUpdateWidget(DenScope old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      // Another family's state (the device switched families): everything below reads it anew.
      old.state.removeListener(_changed);
      widget.state.addListener(_changed);
      _version++;
      _touched.add(Changes.all);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {
        _version++;
        _touched.addAll(widget.state.lastChange);
      });

  @override
  Widget build(BuildContext context) {
    final touched = _touched;
    _touched = {};
    return _DenModel(state: widget.state, version: _version, changed: touched, child: widget.child);
  }
}

class _DenModel extends InheritedModel<String> {
  const _DenModel({required this.state, required this.version, required this.changed, required super.child});

  final AppState state;
  final int version;
  final Set<String> changed;

  @override
  bool updateShouldNotify(_DenModel old) => version != old.version;

  @override
  bool updateShouldNotifyDependent(_DenModel old, Set<String> dependencies) =>
      changed.contains(Changes.all) || dependencies.any(changed.contains);
}

/// A view of the family that a screen shows, such as today's plan or a day's chores. The app
/// computes it from the engine again only when a record type it [reads] has changed, or the day
/// has, and only widgets that show it rebuild ([DenContext.view]).
abstract class DenView<T> {
  const DenView();

  /// The record types it's computed from, besides who's who ([Changes.people]).
  Set<String> get reads;

  /// Tells apart views of one kind with different arguments (a day, a list).
  Object get key => runtimeType;

  T compute(AppState app);
}

extension DenContext on BuildContext {
  /// The app's state, rebuilding this widget on every change. Prefer [watch].
  AppState get app => DenScope.of(this);

  /// The engine, rebuilding this widget on every change. Prefer [watch].
  Den get den => DenScope.of(this).den;

  /// The app's state, rebuilding this widget only when who's who ([Changes.people]) or one of
  /// [types] changes.
  AppState watch(Set<String> types) => DenScope.watch(this, {...Changes.people, ...types});

  /// [view]'s value, computed again only when what it reads changes; this widget rebuilds then.
  T view<T>(DenView<T> view) => watch(view.reads).view(view);

  /// The actions every change goes through. Reading them never rebuilds.
  AppActions get actions => DenScope.read(this).actions;
}
