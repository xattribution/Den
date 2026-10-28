import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../net/hub_client.dart';
import '../../net/hub_push.dart';
import '../../state/app_state.dart';
import '../../web/web_app.dart';

/// Reminders in a browser: one tap turns on reminders from the hub for this device (Web Push),
/// or says plainly why it can't here and what to do. On iPhone that needs Den on the Home
/// Screen and iOS 16.4 or later.
class WebReminders extends StatefulWidget {
  const WebReminders({super.key, this.web, this.client});

  /// The browser, for tests; by default read from the page.
  final WebAppInfo? web;

  /// The hub's push endpoints, for tests.
  final HubPushClient? client;

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

  WebAppInfo get _web => widget.web ?? WebApp.info;

  String get _thing => _web.ios ? (_web.ipad ? 'iPad' : 'iPhone') : 'browser';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final network = context.app.network;
    final client = _client = widget.client ?? (network == null ? null : HubPushClient(network));
    if (pushAvailability(_web) != PushAvailability.ready) return;
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

  void _turnOn() {
    final key = _key;
    final client = _client;
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

  Future<void> _turnOff() async {
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
    Widget block(Widget child) => Padding(padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0), child: child);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (why != null)
          block(AttentionLine(message: why))
        else if (!_loaded)
          block(Text('Checking with the hub', style: context.type.body(c.ink2)))
        else if (_on) ...[
          block(
            Row(
              children: [
                Icon(PhosphorIconsRegular.bellRinging, size: 20, color: c.ink),
                const SizedBox(width: Sp.m),
                Expanded(child: Text('Reminders are on for this $_thing', style: context.type.body(c.ink))),
                TextButton(onPressed: _busy ? null : _turnOff, child: const Text('Turn off')),
              ],
            ),
          ),
        ] else if (_key != null)
          block(
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _busy ? null : _turnOn,
                icon: const Icon(PhosphorIconsRegular.bell, size: 18),
                label: Text('Turn on reminders on this $_thing'),
              ),
            ),
          ),
        if (_note != null) block(Text(_note!, style: context.type.body(c.ink2))),
        if (_error != null) block(AttentionLine(message: _error!, bad: true)),
      ],
    );
  }
}
