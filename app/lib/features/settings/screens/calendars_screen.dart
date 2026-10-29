import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/web/web_app.dart' show WebAppInfo;
import '../../family/family.dart';
import '../state/calendar_feeds.dart';
import '../state/feed_links.dart';
import '../widgets/feed_links_section.dart';

/// Settings → Calendars: on a phone, its own calendars to bring in; for parents, Den in the
/// phone's calendar app (a read-only subscription to the family's calendar on the hub), and
/// calendars by link (a school's, a team's), which the family's hub fetches and keeps up to
/// date, read-only.
class CalendarsScreen extends StatefulWidget {
  const CalendarsScreen({super.key, this.feedLinks, this.web, this.openCalendar});

  /// The hub's calendar links, for tests.
  final FeedLinksSource? feedLinks;

  /// The browser, for tests.
  final WebAppInfo? web;

  /// Opens a webcal address, for tests.
  final Future<bool> Function(Uri webcal)? openCalendar;

  @override
  State<CalendarsScreen> createState() => _CalendarsScreenState();
}

class _CalendarsScreenState extends State<CalendarsScreen> {
  final _url = TextEditingController();
  final _label = TextEditingController();
  String? _addError;
  String? _added;
  String? _removing;
  String? _removeError;
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _addError = "Paste the calendar's address, which starts with https or webcal.");
      return;
    }
    setState(() {
      _busy = true;
      _addError = null;
      _added = null;
    });
    final feeds = context.calendarFeeds;
    final problem = await tryWrite(() => feeds.add(url, label: _label.text.trim()));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _addError = problem;
      if (problem == null) {
        _added = _label.text.trim().isEmpty ? 'Added. The hub fetches it in a minute or two.' : 'Added ${_label.text.trim()}. The hub fetches it in a minute or two.';
        _url.clear();
        _label.clear();
      }
    });
  }

  Future<void> _remove(Subscription s) async {
    setState(() {
      _busy = true;
      _removeError = null;
    });
    final feeds = context.calendarFeeds;
    final problem = await tryWrite(() => feeds.remove(s.id));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _removeError = problem;
      if (problem == null) _removing = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.subscription});
    final c = context.colors;
    final t = context.text;
    final parent = app.allows(DenAction.manageFamily);
    final phone = app.phoneCalendars;
    final feeds = app.den.subscriptions;
    return DenPage(
      title: 'Calendars',
      children: [
        if (phone != null)
          GroupCard(
            child: ListenableBuilder(
              listenable: phone,
              builder: (context, _) => NavRow(
                icon: PhosphorIconsRegular.deviceMobile,
                label: 'Calendars on this phone',
                value: phone.picks.isEmpty ? 'None' : '${phone.picks.length}',
                onTap: () => context.push('/settings/phone-calendars'),
              ),
            ),
          ),
        if (parent) ...[
          FeedLinksSection(source: widget.feedLinks, web: widget.web, open: widget.openCalendar),
          DenSection(
            title: 'Calendars by link',
            child: feeds.isEmpty
                ? const EmptyState(compact: true, message: "A school's or a team's calendar shows here once you add it.")
                : Column(
                    children: ruled([
                      for (final s in feeds)
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
                                          Text(s.label.isEmpty ? s.url : s.label, style: t.body(c.ink)),
                                          Text(
                                            s.status.isNotEmpty ? s.status : 'For ${app.seenBy(s.targetSpace).toLowerCase()}',
                                            style: t.meta(c.ink2),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (_removing != s.id)
                                    TextButton(
                                      onPressed: () => setState(() => _removing = s.id),
                                      style: TextButton.styleFrom(foregroundColor: c.destructive),
                                      child: const Text('Remove'),
                                    ),
                                ],
                              ),
                            ),
                            DenReveal(
                              visible: _removing == s.id,
                              child: _removing != s.id
                                  ? const SizedBox(width: double.infinity)
                                  : ConfirmPanel(
                                      message: 'Its events leave the calendar.',
                                      confirmLabel: 'Remove ${s.label.isEmpty ? 'it' : s.label}',
                                      destructive: true,
                                      busy: _busy,
                                      error: _removeError,
                                      onConfirm: () => _remove(s),
                                      onCancel: () => setState(() => _removing = null),
                                    ),
                            ),
                          ],
                        ),
                    ]),
                  ),
          ),
          DenSection(
            title: 'Add a calendar by link',
            carded: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LabeledField(
                  label: 'Its address',
                  error: _addError,
                  child: TextField(
                    controller: _url,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    style: t.body(c.ink),
                    decoration: const InputDecoration(hintText: 'https://school.example.org/calendar.ics'),
                  ),
                ),
                const SizedBox(height: Sp.l),
                LabeledField(
                  label: 'A name for it',
                  child: TextField(
                    controller: _label,
                    textCapitalization: TextCapitalization.words,
                    style: t.body(c.ink),
                    decoration: const InputDecoration(hintText: 'Oak Grove School'),
                  ),
                ),
                const SizedBox(height: Sp.l),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(onPressed: _busy ? null : _add, child: const Text('Add calendar')),
                ),
                if (_added != null) ...[const SizedBox(height: Sp.s), DoneRow(message: _added!)],
              ],
            ),
          ),
        ] else if (phone == null)
          const EmptyState(message: 'A parent adds calendars for the family.'),
      ],
    );
  }
}
