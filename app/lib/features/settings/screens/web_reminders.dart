import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/hub_client.dart';
import '../../../platform/sync/hub_push.dart';
import '../../../app/app_state.dart';
import '../../../app/household.dart';
import '../../../platform/web/web_app.dart';

/// Reminders in a browser: one tap turns on reminders from the hub for this device (Web Push),
/// or says plainly why it can't here and what to do. On iPhone that needs Den on the Home
/// Screen and iOS 16.4 or later.
///
/// A browser holding several families has one subscription for all of them ([PushPlan]): made
/// with the key the families on the server share and registered with each, so one tap turns
/// on every family's reminders; a family whose server doesn't share it is named.
class WebReminders extends StatefulWidget {
  const WebReminders({super.key, this.web, this.client, this.families});

  /// The browser, for tests; by default read from the page.
  final WebAppInfo? web;

  /// The hub's push endpoints, for tests.
  final HubPushClient? client;

  /// Every family's push endpoints, the one Settings is for first, for tests; by default the
  /// household's when the device holds several families.
  final List<PushFamily>? families;

  @override
  State<WebReminders> createState() => _WebRemindersState();
}

class _WebRemindersState extends State<WebReminders> {
  HubPushClient? _client;
  bool _started = false;
  String? _key;
  bool _on = false;
  bool _busy = false;
  bool _loaded = false;
  String? _note;
  String? _error;

  /// With several families: what one subscription reaches.
  PushPlan? _plan;

  WebAppInfo get _web => widget.web ?? WebApp.info;

  String get _thing => _web.ios ? (_web.ipad ? 'iPad' : 'iPhone') : 'browser';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final network = context.watch(const {}).network;
    final client = _client = widget.client ?? (network == null ? null : HubPushClient(network));
    if (pushAvailability(_web) != PushAvailability.ready) return;
    final families = widget.families ?? _householdFamilies(context);
    if (families != null && families.length > 1) {
      _loadSeveral(families);
      return;
    }
    if (client == null) {
      _loaded = true;
      _error = "Reminders come from the family's hub, and this $_thing isn't connected to one.";
      return;
    }
    _load(client);
  }

  /// The hub's key and this device's state, fetched ahead so the tap can subscribe at once.
  Future<void> _load(HubPushClient client) async {
    try {
      final status = await client.status();
      final browser = await WebApp.pushSubscription(status.key);
      if (!mounted) return;
      setState(() {
        _key = status.key;
        _on = status.subscribed && browser != null;
        _loaded = true;
      });
    } on HubException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loaded = true;
        });
      }
    }
  }

  /// Every family on this device with a hub to ask, the one Settings is for first; null for a
  /// device in one family.
  List<PushFamily>? _householdFamilies(BuildContext context) {
    final home = Household.maybeOf(context);
    if (home == null || !home.several) return null;
    final shown = home.of(DenScope.read(context).den) ?? home.active;
    return [
      for (final log in [shown, ...home.families.where((l) => !identical(l, shown))])
        if (log.den.isApproved && log.network != null) PushFamily(log.name, HubPushClient(log.network!)),
    ];
  }

  /// Where every family stands, and whether this browser's subscription is the one they share.
  Future<void> _loadSeveral(List<PushFamily> families) async {
    try {
      final plan = await PushPlan.look(families);
      final browser = await WebApp.pushState(plan.key);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _key = plan.key;
        _on = plan.on && browser.subscription != null && browser.same;
        _loaded = true;
      });
    } on HubException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loaded = true;
        });
      }
    }
  }

  void _turnOn() {
    final key = _key;
    final client = _client;
    final plan = _plan;
    if (plan != null && key != null && !_busy) {
      // Straight from the tap, before anything is awaited.
      final subscribing = WebApp.subscribe(key);
      setState(() {
        _busy = true;
        _error = null;
        _note = null;
      });
      _finishSeveral(subscribing, plan);
      return;
    }
    if (key == null || client == null || _busy) return;
    // Straight from the tap, before anything is awaited: Safari asks for permission only then.
    final subscribing = WebApp.subscribe(key);
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    _finish(subscribing, client);
  }

  Future<void> _finish(Future<WebPushSubscription> subscribing, HubPushClient client) async {
    try {
      final subscription = await subscribing;
      final status = await client.subscribe(subscription);
      await client.test();
      if (mounted) {
        setState(() {
          _on = status.subscribed;
          _note = 'Reminders are on. A test one is on its way.';
        });
      }
    } on WebPushException catch (e) {
      if (mounted) {
        setState(() => _error = switch (e.reason) {
              'NotAllowedError' => "Notifications are off for Den. Turn them on in this $_thing's Settings, Notifications, Den.",
              'not-ready' => 'Den is still getting ready on this $_thing. Try again in a moment.',
              _ => "This $_thing couldn't turn on reminders. Try again.",
            });
      }
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishSeveral(Future<WebPushSubscription> subscribing, PushPlan plan) async {
    try {
      final subscription = await subscribing;
      await plan.register(subscription);
      await plan.reached.first.client.test();
      if (mounted) {
        setState(() {
          _on = true;
          _note = plan.reached.length > 1
              ? 'Reminders are on from ${_names([for (final f in plan.reached) f.name])}. A test one is on its way.'
              : 'Reminders are on. A test one is on its way.';
        });
      }
    } on WebPushException catch (e) {
      if (mounted) setState(() => _error = _pushError(e));
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _pushError(WebPushException e) => switch (e.reason) {
        'NotAllowedError' => "Notifications are off for Den. Turn them on in this $_thing's Settings, Notifications, Den.",
        'not-ready' => 'Den is still getting ready on this $_thing. Try again in a moment.',
        _ => "This $_thing couldn't turn on reminders. Try again.",
      };

  static String _names(List<String> names) =>
      names.length < 2 ? names.join() : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';

  Future<void> _turnOff() async {
    final plan = _plan;
    if (plan != null) {
      setState(() {
        _busy = true;
        _error = null;
        _note = null;
      });
      try {
        for (final f in plan.reached) {
          await f.client.unsubscribe();
        }
        await WebApp.unsubscribe();
        if (mounted) setState(() => _on = false);
      } on HubException catch (e) {
        if (mounted) setState(() => _error = e.message);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    final client = _client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });
    try {
      await client.unsubscribe();
      await WebApp.unsubscribe();
      if (mounted) setState(() => _on = false);
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final availability = pushAvailability(_web);
    final why = switch (availability) {
      PushAvailability.ready => null,
      PushAvailability.addToHomeScreen =>
        'Reminders work once Den is on your Home Screen. In Safari, tap Share, then Add to Home Screen, and open Den from there.',
      PushAvailability.updateIos => 'Reminders on this $_thing need iOS 16.4 or later. Update it in Settings, General, Software Update.',
      PushAvailability.needsHttps => "Reminders need Den's https address. Ask whoever set up the hub for it.",
      PushAvailability.blocked => "Notifications are off for Den. Turn them on in this $_thing's Settings, Notifications, Den.",
      PushAvailability.unsupported => "This browser can't show Den's reminders.",
    };
    final t = context.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (why != null)
            NoticeLine(icon: PhosphorIconsRegular.bellSlash, message: why)
          else if (!_loaded)
            Text('Checking with the hub', style: t.body(c.ink2))
          else if (_on)
            Row(
              children: [
                Icon(PhosphorIconsRegular.bellRinging, size: 22, color: c.ink),
                const SizedBox(width: Sp.m),
                Expanded(
                  child: Text(
                    (_plan?.reached.length ?? 1) > 1
                        ? 'Reminders are on for this $_thing, from ${_names([for (final f in _plan!.reached) f.name])}'
                        : 'Reminders are on for this $_thing',
                    style: t.body(c.ink),
                  ),
                ),
                TextButton(onPressed: _busy ? null : _turnOff, child: const Text('Turn off')),
              ],
            )
          else if (_key != null)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _busy ? null : _turnOn,
                icon: const Icon(PhosphorIconsRegular.bell, size: 18),
                label: Text((_plan?.reached.length ?? 1) > 1 ? 'Turn on reminders from every family' : 'Turn on reminders on this $_thing'),
              ),
            ),
          if (why == null && _loaded && (_plan?.unreached.isNotEmpty ?? false)) ...[
            const SizedBox(height: Sp.s),
            NoticeLine(
              icon: PhosphorIconsRegular.bellSlash,
              message: "Reminders from ${_names(_plan!.unreached)} can't come to this $_thing yet. "
                  'Whoever runs your Den server can turn that on.',
            ),
          ],
          if (_note != null) ...[const SizedBox(height: Sp.s), Text(_note!, style: t.meta(c.ink2))],
          if (_error != null) ...[
            const SizedBox(height: Sp.s),
            Text(_error!, style: t.meta(c.destructive)),
          ],
        ],
      ),
    );
  }
}
