import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/pairing.dart';
import '../../../platform/web/web_app.dart';
import '../state/trust_actions.dart';
import 'person_sheets.dart' show sheetPadding;

/// Invites someone (Invite.dc.html): a one-time link and four words for one person, sent
/// through the share sheet. They open it and are in as themselves at once (the invite carries a
/// key this phone made, good for a day; Today says when they're in, with That wasn't them), or,
/// with Let them in right away off, a parent lets them in with one tap on Today. [memberId]
/// chooses who it's for; without it the sheet asks.
Future<void> showInviteSheet(BuildContext context, {String? memberId, bool shared = false}) =>
    showDenSheet<void>(context, builder: (_) => InviteSheet(memberId: memberId, shared: shared));

class InviteSheet extends StatefulWidget {
  const InviteSheet({super.key, this.memberId, this.now, this.shared = false});

  final String? memberId;

  /// The clock for when the invite stops working; tests pass a fixed time.
  final DateTime Function()? now;

  /// An invite for a shared display, which names nobody (Settings, Kitchen screen).
  final bool shared;

  @override
  State<InviteSheet> createState() => _InviteSheetState();
}

enum _Sent { not, shared, copied }

class _InviteSheetState extends State<InviteSheet> {
  late String? _for = widget.memberId;
  InviteMessage? _message;
  String? _error;
  bool _loading = false;
  _Sent _sent = _Sent.not;
  String? _shareError;
  PairingService? _pairing;

  /// Whoever opens it is let in at once ("Let them in right away"), or a parent approves them.
  bool _letIn = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pairing = Pairing.of(context);
    if (pairing == _pairing) return;
    _pairing = pairing;
    if (_for != null || widget.shared) _load();
  }

  Future<void> _load() async {
    final before = _message;
    final trust = context.trustActions;
    setState(() {
      _loading = true;
      _error = null;
      _message = null;
      _sent = _Sent.not;
      _shareError = null;
    });
    // An invite made for this sheet and never sent lets nobody in once it's replaced.
    final unsent = before?.inviteKey;
    if (unsent != null) unawaited(trust.withdrawInvite(unsent).catchError((Object _) {}));
    try {
      final message = await _pairing!.createInvite(memberId: widget.shared ? null : _for, letIn: _letIn);
      if (mounted) {
        setState(() {
          _message = message;
          _loading = false;
        });
      }
    } on PairingException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  void _choose(String member) {
    if (member == _for) return;
    setState(() => _for = member);
    _load();
  }

  void _setLetIn(bool on) {
    if (on == _letIn) return;
    setState(() => _letIn = on);
    _load();
  }

  /// Hands the message to the share sheet, or copies it where there's none. Called straight
  /// from the tap: browsers open the share sheet only for a user gesture.
  Future<void> _send(InviteMessage message, Rect? origin) async {
    if (Capabilities.web) {
      final outcome = await WebApp.share(message.text);
      if (!mounted) return;
      setState(() {
        _shareError = outcome == ShareOutcome.failed ? "Couldn't open the share sheet. Copy the invite instead." : null;
        _sent = switch (outcome) {
          ShareOutcome.shared => _Sent.shared,
          ShareOutcome.copied => _Sent.copied,
          _ => _sent,
        };
      });
      return;
    }
    final result = await SharePlus.instance.share(
      ShareParams(text: message.text, subject: 'Join us on Den', sharePositionOrigin: origin),
    );
    if (mounted && result.status != ShareResultStatus.dismissed) setState(() => _sent = _Sent.shared);
  }

  Future<void> _copy(InviteMessage message) async {
    await Clipboard.setData(ClipboardData(text: message.text));
    if (mounted) setState(() => _sent = _Sent.copied);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final t = context.text;
    final member = app.memberById(_for);
    final people = [for (final m in app.den.members) if (m.id != app.me?.id) m];
    final title = widget.shared ? 'Invite a shared display' : (member == null ? 'Invite someone' : 'Invite ${member.name}');
    final children = <Widget>[SheetHeader(title: title)];

    if (!widget.shared && widget.memberId == null) {
      children.addAll([
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
          child: Text('Who is it for?', style: t.meta(c.ink2)),
        ),
        const SizedBox(height: Sp.s),
        if (people.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
            child: Text(tidy('Add them to the family first: Family, then Add.'), style: t.body(c.ink2)),
          )
        else
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              for (final m in people)
                PersonPill(face: DenAvatar(m, size: 32), name: m.name, selected: m.id == _for, onTap: () => _choose(m.id)),
            ],
          ),
        const SizedBox(height: Sp.l),
      ]);
    }

    if (!widget.shared && _for != null) {
      children.addAll([
        GroupCard(
          child: SwitchLine(
            label: 'Let them in right away',
            detail: _letIn
                ? "No approving: they're in when they open it. Good for a day, on one phone or tablet."
                : 'You approve them on Today once they open it.',
            value: _letIn,
            onChanged: _loading ? null : _setLetIn,
            reason: 'Making the invite',
          ),
        ),
        const SizedBox(height: Sp.l),
      ]);
    }

    final message = _message;
    if (_loading) {
      children.add(Padding(
        padding: const EdgeInsets.all(Sp.l),
        child: Text('Making the invite', style: t.body(c.ink2)),
      ));
    } else if (_error != null) {
      children.add(_NoInvite(message: _error!, onRetry: _load));
    } else if (message != null) {
      children.addAll(_invite(context, message, member));
    }
    return SingleChildScrollView(
      padding: sheetPadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  List<Widget> _invite(BuildContext context, InviteMessage message, Member? member) {
    final c = context.colors;
    final t = context.text;
    final now = (widget.now ?? DateTime.now)();
    final expired = message.expires <= now.millisecondsSinceEpoch;
    final until = DateFormat(message.letsIn ? "EEEE 'at' h:mm a" : 'EEEE').format(DateTime.fromMillisecondsSinceEpoch(message.expires));
    final who = member?.name ?? (widget.shared ? 'the display' : 'them');
    return [
      GroupCard(
        padding: const EdgeInsets.all(DenLayout.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("The message they'll get", style: t.meta(c.ink2)),
            const SizedBox(height: Sp.s),
            Text(message.text, style: t.body(c.ink)),
            const SizedBox(height: Sp.m),
            const RowRule(),
            const SizedBox(height: Sp.m),
            Text(expired ? 'This code ran out' : 'Their code, good until $until, once', style: t.meta(c.ink2)),
            const SizedBox(height: Sp.xs),
            SelectableText(
              message.code,
              style: t.sheetTitle(expired ? c.ink3 : c.ink).copyWith(fontSize: 24),
            ),
          ],
        ),
      ),
      const SizedBox(height: Sp.l),
      if (expired)
        OutlinedButton(onPressed: _load, child: const Text('Make a new invite'))
      else if (_sent == _Sent.not) ...[
        Row(
          children: [
            Expanded(
              flex: 2,
              child: Builder(
                builder: (button) => FilledButton.icon(
                  onPressed: () {
                    final box = button.findRenderObject() as RenderBox?;
                    _send(message, box == null ? null : box.localToGlobal(Offset.zero) & box.size);
                  },
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  icon: const Icon(PhosphorIconsBold.export, size: 22),
                  label: const Text('Send invite', maxLines: 1, softWrap: false),
                ),
              ),
            ),
            const SizedBox(width: Sp.s),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _copy(message),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                child: const Text('Copy', maxLines: 1, softWrap: false),
              ),
            ),
          ],
        ),
        if (_shareError != null) ...[
          const SizedBox(height: Sp.s),
          Text(tidy(_shareError!), style: t.meta(c.destructive)),
        ],
      ] else
        GroupCard(
          padding: const EdgeInsets.all(DenLayout.cardPadding),
          child: Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_sent == _Sent.copied ? PhosphorIconsBold.check : PhosphorIconsRegular.clock, size: 22, color: c.ink),
                const SizedBox(width: Sp.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _sent == _Sent.copied ? 'Copied. Paste it into a message to $who.' : 'Waiting for $who to open it',
                        style: t.rowTitle(c.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tidy(message.letsIn
                            ? "They're in as soon as they open it. Today says so, in case it wasn't them."
                            : "You'll get one tap on Today to let them in."),
                        style: t.meta(c.ink2),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }
}

/// No invite could be made: why, and the way out. Without a hub, a phone can still add a
/// device in the same room from Advanced.
class _NoInvite extends StatelessWidget {
  const _NoInvite({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final nearby = !Capabilities.web;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ErrorState(message: message, actionLabel: 'Try again', onAction: onRetry),
        if (nearby)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                GoRouter.of(context).push('/settings/advanced/hub/nearby');
              },
              child: const Text('Add a device in the same room'),
            ),
          ),
      ],
    );
  }
}

