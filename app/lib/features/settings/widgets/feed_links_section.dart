import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/app_state.dart';
import '../../../design/forms/forms.dart' show FieldError, Hang;
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/hub_client.dart' show HubException;
import '../../../platform/web/web_app.dart';
import '../../family/family.dart';
import '../state/feed_links.dart';

/// Settings, Calendars: "Show Den in iPhone Calendar". One tap makes a read-only link to the
/// family's calendar on the hub and hands it to the phone's calendar app as a subscription
/// (`webcal://`), so Den's events show beside work and school ones there and stay up to date.
/// "Just one person's" makes one for someone's events. "A link for another family" makes one for
/// the family's Everyone events only, to send to another family, whose hub adds it as a calendar
/// by link and keeps it up to date (until Groups carry the offer and the one-tap accept). The
/// links made so far are listed by where they went, each with Turn off. Where the calendar app
/// doesn't ask on its own, it says plainly how to add the link by hand, with Copy link.
class FeedLinksSection extends StatefulWidget {
  const FeedLinksSection({super.key, this.source, this.web, this.open});

  /// The hub's links; by default the family hub's, when there is one.
  final FeedLinksSource? source;

  /// The browser, for tests; by default read from the page.
  final WebAppInfo? web;

  /// Opens a `webcal://` address, for tests; by default the system's open-URL path.
  final Future<bool> Function(Uri webcal)? open;

  @override
  State<FeedLinksSection> createState() => _FeedLinksSectionState();
}

class _FeedLinksSectionState extends State<FeedLinksSection> {
  FeedLinksSource? _source;
  bool _sourceRead = false;
  List<FeedLink>? _links;
  String? _loadError;
  FeedLink? _made;
  bool _opened = false;
  bool _copied = false;
  bool _busy = false;
  String? _error;
  String? _removing;
  String? _removeError;
  bool _forFamily = false;
  final _family = TextEditingController();
  String? _familyError;

  @override
  void dispose() {
    _family.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sourceRead) return;
    _sourceRead = true;
    final network = DenScope.read(context).network;
    _source = widget.source ?? (network != null && (network.isHub || network.hubDevice != null) ? HubFeedLinks(network) : null);
    _load();
  }

  Future<void> _load() async {
    final source = _source;
    if (source == null) return;
    try {
      final links = await source.list();
      if (mounted) setState(() => _links = links);
    } on Object catch (e) {
      if (mounted) setState(() => _loadError = e is HubException ? e.message : "Couldn't reach the hub. Try again.");
    }
  }

  bool get _ios => Capabilities.iOS || (widget.web ?? WebApp.info).ios;

  /// "iPhone Calendar", "iPad Calendar", or a calendar app anywhere else.
  String get _app {
    final web = widget.web ?? WebApp.info;
    if (web.ios) return web.ipad ? 'iPad Calendar' : 'iPhone Calendar';
    if (Capabilities.iOS) return 'iPhone Calendar';
    return 'your calendar app';
  }

  String _labelFor(AppState app) {
    final me = app.me?.name;
    final device = !_ios ? 'calendar' : ((widget.web ?? WebApp.info).ipad ? 'iPad' : 'iPhone');
    return me == null ? 'A $device' : "$me's $device";
  }

  Future<bool> _openCalendar(String webcal) async {
    final uri = Uri.parse(webcal);
    final open = widget.open;
    if (open != null) return open(uri);
    try {
      // In the Home Screen app the address is handed to iOS in place, which asks to subscribe.
      return await launchUrl(uri, webOnlyWindowName: '_self');
    } on Object {
      return false;
    }
  }

  Future<void> _make({String feed = 'family', String? label}) async {
    final source = _source;
    if (source == null) return;
    final app = DenScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
      _made = null;
      _copied = false;
    });
    try {
      final link = await source.create(feed: feed, label: label ?? _labelFor(app));
      if (!mounted) return;
      setState(() {
        _made = link;
        _links = [link, ...?_links];
        if (link.shared) {
          _forFamily = false;
          _family.clear();
        }
      });
      final webcal = link.webcal;
      // A link for another family goes to them, not to this phone's calendar.
      if (webcal != null && !link.shared) {
        final opened = await _openCalendar(webcal);
        if (mounted) setState(() => _opened = opened);
      }
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object {
      if (mounted) setState(() => _error = "Couldn't reach the hub. Check the connection, then try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A link for another family, named for them: "The Smiths".
  Future<void> _forAnotherFamily() async {
    final name = _family.text.trim();
    if (name.length > 60) {
      setState(() => _familyError = 'Keep it to 60 letters or fewer.');
      return;
    }
    setState(() => _familyError = null);
    await _make(feed: FeedLink.sharedFeed, label: name.isEmpty ? 'Another family' : name);
  }

  Future<void> _justOne() async {
    final app = DenScope.read(context);
    final pick = await showPeoplePicker(context, title: 'Whose calendar?', people: app.den.members);
    final member = pick?.member;
    if (member != null && mounted) await _make(feed: member);
  }

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _remove(FeedLink link) async {
    setState(() {
      _busy = true;
      _removeError = null;
    });
    try {
      await _source!.remove(link.id);
      if (!mounted) return;
      setState(() {
        _links = [...?_links]..removeWhere((l) => l.id == link.id);
        _removing = null;
        if (_made?.id == link.id) _made = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _removeError = e is HubException ? e.message : "Couldn't reach the hub. Try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final t = context.text;
    final f = app.formats;
    final title = 'Den in $_app';
    if (_source == null) {
      return DenSection(
        title: title,
        child: EmptyState(
          compact: true,
          message: 'Den can show in $_app once the family has a hub. Set one up in Advanced, Hub and sync.',
        ),
      );
    }
    final links = _links ?? const <FeedLink>[];
    final made = _made;
    final children = <Widget>[];
    if (_loadError != null) {
      children.add(ErrorState(message: _loadError!, actionLabel: 'Try again', onAction: () {
        setState(() => _loadError = null);
        _load();
      }));
    }
    if (links.isNotEmpty) {
      children.add(GroupCard(
        child: Column(
          children: ruled([
            for (final link in links)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Row(
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: Sp.s),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(link.label, style: t.body(c.ink)),
                                Text(
                                  tidy('${link.shared ? 'Everyone events, for another family' : link.family ? "Everyone's events" : "${link.feedName ?? 'One person'}'s events"}, '
                                      'since ${f.short(f.localDate(link.made))}'),
                                  style: t.meta(c.ink2),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_removing != link.id)
                          TextButton(
                            onPressed: () => setState(() => _removing = link.id),
                            style: TextButton.styleFrom(foregroundColor: c.destructive),
                            child: const Text('Turn off'),
                          ),
                      ],
                    ),
                  ),
                  DenReveal(
                    visible: _removing == link.id,
                    child: _removing != link.id
                        ? const SizedBox(width: double.infinity)
                        : ConfirmPanel(
                            message: link.shared
                                ? "The other family's Den stops showing your events."
                                : "$_app stops getting Den's changes. What it has stays until you remove it there.",
                            confirmLabel: 'Turn off ${link.label}',
                            destructive: true,
                            busy: _busy,
                            error: _removeError,
                            onConfirm: () => _remove(link),
                            onCancel: () => setState(() => _removing = null),
                          ),
                  ),
                ],
              ),
          ]),
        ),
      ));
    }
    if (made != null && made.url != null && made.shared) {
      children.add(GroupCard(
        padding: const EdgeInsets.all(DenLayout.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tidy('Send this link to ${made.label}.'), style: t.rowTitle(c.ink)),
            const SizedBox(height: Sp.xs),
            Text(
              tidy('A parent there adds it in Den: Settings, Calendars, Add a calendar by link. Their Den '
                  'keeps it up to date until you turn it off here.'),
              style: t.body(c.ink2),
            ),
            const SizedBox(height: Sp.m),
            Wrap(
              spacing: Sp.s,
              runSpacing: Sp.s,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _copy(made.url!),
                  icon: Icon(_copied ? PhosphorIconsBold.check : PhosphorIconsRegular.copy, size: 20),
                  label: Text(_copied ? 'Copied' : 'Copy link'),
                ),
              ],
            ),
          ],
        ),
      ));
    } else if (made != null && made.url != null) {
      children.add(GroupCard(
        padding: const EdgeInsets.all(DenLayout.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tidy(_opened ? '$_app should ask to subscribe now.' : '$_app didn’t open on its own.'),
              style: t.rowTitle(c.ink),
            ),
            const SizedBox(height: Sp.xs),
            Text(
              tidy(_ios
                  ? '${_opened ? 'If it didn’t ask, copy the link.' : 'Copy the link.'} Then open Calendar, tap '
                      'Calendars, then Add Calendar, then Add Subscription Calendar, and paste it.'
                  : 'Copy the link and add it to your calendar app as a calendar from a URL. In Google '
                      'Calendar, that’s Other calendars, then From URL, on a computer.'),
              style: t.body(c.ink2),
            ),
            const SizedBox(height: Sp.m),
            Wrap(
              spacing: Sp.s,
              runSpacing: Sp.s,
              children: [
                if (made.webcal != null)
                  OutlinedButton.icon(
                    onPressed: () async {
                      final opened = await _openCalendar(made.webcal!);
                      if (mounted) setState(() => _opened = opened);
                    },
                    icon: const Icon(PhosphorIconsRegular.calendarPlus, size: 20),
                    label: Text(_ios ? 'Open Calendar' : 'Open the calendar app'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => _copy(made.url!),
                  icon: Icon(_copied ? PhosphorIconsBold.check : PhosphorIconsRegular.copy, size: 20),
                  label: Text(_copied ? 'Copied' : 'Copy link'),
                ),
              ],
            ),
          ],
        ),
      ));
    }
    children.add(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Once a link is made here, the panel above is what to do next.
        if (made == null) ...[
          FilledButton.icon(
            onPressed: _busy ? null : () => _make(),
            icon: const Icon(PhosphorIconsBold.calendarPlus, size: 20),
            label: Text('Show Den in $_app'),
          ),
          const SizedBox(height: Sp.xs),
        ],
        Hang(
          by: Sp.m,
          child: TextButton(onPressed: _busy ? null : _justOne, child: const Text("Just one person's events")),
        ),
        Hang(
          by: Sp.m,
          child: TextButton(
            onPressed: _busy ? null : () => setState(() => _forFamily = !_forFamily),
            child: const Text('A link for another family'),
          ),
        ),
        DenReveal(
          visible: _forFamily,
          child: !_forFamily
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: Sp.s),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tidy('Everyone events only: titles, times, places and notes. Never Parents-only or Just-me '
                            'things, and never calendars another family shared with you.'),
                        style: t.body(c.ink2),
                      ),
                      const SizedBox(height: Sp.m),
                      LabeledField(
                        label: 'Which family is it for?',
                        error: _familyError,
                        child: TextField(
                          controller: _family,
                          textCapitalization: TextCapitalization.words,
                          style: t.body(c.ink),
                          decoration: const InputDecoration(hintText: 'The Smiths'),
                        ),
                      ),
                      const SizedBox(height: Sp.m),
                      FilledButton(onPressed: _busy ? null : _forAnotherFamily, child: const Text('Make the link')),
                    ],
                  ),
                ),
        ),
        if (_error != null) ...[
          const SizedBox(height: Sp.xs),
          FieldError(_error, body: true),
        ],
      ],
    ));
    return DenSection(
      title: title,
      carded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, child) in children.indexed) ...[if (i > 0) const SizedBox(height: Sp.l), child],
        ],
      ),
    );
  }
}
