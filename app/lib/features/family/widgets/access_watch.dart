import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../../../app/app_state.dart';
import '../state/family_needs.dart';
import '../state/trust_actions.dart';

/// Ends sitters' access on time. While Den is open on a parent's own device, a sitter whose last
/// day has passed has their devices removed, the usual way (a revocation naming the last of
/// their changes this device holds, and new keys). Nothing else does it: a sitter's own clock
/// can't be trusted, and a hub never makes trust decisions. Checks when people or devices change
/// and every quarter hour, so the day turning over is noticed too.
class AccessWatch extends StatefulWidget {
  const AccessWatch({super.key, required this.child});

  final Widget child;

  @override
  State<AccessWatch> createState() => _AccessWatchState();
}

class _AccessWatchState extends State<AccessWatch> {
  Timer? _timer;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 15), (_) => _check());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.watch(const {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (!mounted || _running) return;
    final app = DenScope.read(context);
    if (!app.allowsTrust(DenAction.manageFamily)) return;
    final den = app.den;
    final today = app.today;
    if (!den.members.any((m) => m.accessEndedOn(today) && devicesOf(den, m.id).isNotEmpty)) return;
    _running = true;
    final trust = context.trustActions;
    await tryWrite(trust.endExpiredAccess);
    _running = false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
