import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../app/app_state.dart';
import '../../design/layout.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../platform/sync/hub_client.dart' show HubException;
import '../../platform/web/web_app.dart';
import 'linked_families.dart';
import 'state/link_actions.dart';

/// Settings → Linked families: the families this one is linked with, each opening its page; for
/// parents, Link a family (the address to send the other family's parent) and Paste a family
/// link (one the other family's parent sent).
class LinkedFamiliesScreen extends StatefulWidget {
  const LinkedFamiliesScreen({super.key, this.source});

  /// Where links are made and accepted, for tests; by default the family's hub.
  final FamilyLinksSource? source;

  @override
  State<LinkedFamiliesScreen> createState() => _LinkedFamiliesScreenState();
}

class _LinkedFamiliesScreenState extends State<LinkedFamiliesScreen> {
  String? _url;
  bool _copied = false;
  bool _busy = false;
  String? _error;
  String? _done;

  FamilyLinksSource? _source() {
    if (widget.source != null) return widget.source;
    final network = DenScope.read(context).network;
    return network != null && (network.isHub || network.hubDevice != null) ? HubFamilyLinks(network) : null;
  }

  Future<void> _link() async {
    final source = _source();
    if (source == null) {
      setState(() => _error = 'Linking families needs the family\'s hub. Set one up first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
      _url = null;
      _copied = false;
    });
    final den = DenScope.read(context).den;
    String? id;
    final problem = await tryWrite(() async => id = await LinkActions(den).add());
    String? url;
    String? failed = problem;
    if (problem == null) {
      try {
        url = await source.offer(id!);
      } on HubException catch (e) {
        failed = e.message;
      } on Object {
        failed = 'Den couldn\'t reach the family\'s hub. Try again in a minute.';
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failed;
      _url = url;
    });
  }

  Future<void> _copy() async {
    final url = _url;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) setState(() => _copied = true);
  }

  /// Called straight from the tap, so a browser lets it read the clipboard.
  Future<void> _paste() async {
    final pasted = await WebApp.paste();
    String? text = pasted.text;
    if (text == null) {
      try {
        text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      } on Object {
        text = null;
      }
    }
    if (!mounted) return;
    final url = text?.trim() ?? '';
    final id = familyLinkId(url);
    if (id == null) {
      setState(() => _error = 'Copy the family link the other family\'s parent sent, then tap Paste a family link.');
      return;
    }
    final source = _source();
    if (source == null) {
      setState(() => _error = 'Linking families needs the family\'s hub. Set one up first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    final den = DenScope.read(context).den;
    String? failed;
    if (den.familyLink(id) == null) failed = await tryWrite(() => LinkActions(den).add(id: id));
    String? name;
    if (failed == null) {
      try {
        name = await source.accept(url);
      } on HubException catch (e) {
        failed = e.message;
      } on Object {
        failed = 'Den couldn\'t reach the family\'s hub. Try again in a minute.';
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failed;
      if (failed == null) _done = 'Linked with ${linkedFamilyName(name ?? '')}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.familyLink});
    final c = context.colors;
    final t = context.text;
    final parent = app.allows(DenAction.manageFamily);
    final links = [for (final l in app.den.familyLinks) if (l.status != LinkStatus.ended) l];
    final url = _url;
    return DenPage(
      title: 'Linked families',
      children: [
        if (links.isEmpty)
          EmptyState(
            compact: true,
            message: parent
                ? 'Link with another family to share your calendar and lists with them.'
                : 'No linked families yet. A parent links with another family.',
          )
        else
          GroupCard(
            child: Column(
              children: ruled([
                for (final l in links)
                  NavRow(
                    icon: PhosphorIconsRegular.usersThree,
                    label: l.status == LinkStatus.waiting ? 'Waiting for the other family' : linkedFamilyName(l.name),
                    detail: l.problem ?? (l.status == LinkStatus.waiting ? 'Send them the link' : _shared(l)),
                    onTap: () => context.push('/settings/linked/${l.id}'),
                  ),
              ]),
            ),
          ),
        if (parent) ...[
          GroupCard(
            child: Column(
              children: ruled([
                NavRow(
                  icon: PhosphorIconsRegular.link,
                  label: 'Link a family',
                  chevron: false,
                  onTap: _busy ? null : _link,
                ),
                NavRow(
                  icon: PhosphorIconsRegular.clipboardText,
                  label: 'Paste a family link',
                  chevron: false,
                  onTap: _busy ? null : _paste,
                ),
              ], indent: 36),
            ),
          ),
          if (url != null)
            DenSection(
              title: 'Send this to the other family\'s parent',
              carded: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SelectableText(url, style: t.meta(c.ink)),
                  const SizedBox(height: Sp.m),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: _copy,
                      icon: Icon(_copied ? PhosphorIconsBold.check : PhosphorIconsRegular.copy, size: 20),
                      label: Text(_copied ? 'Copied' : 'Copy link'),
                    ),
                  ),
                ],
              ),
            ),
          if (_done != null) DoneRow(message: _done!),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
              child: Semantics(liveRegion: true, child: Text(_error!, style: t.meta(c.destructive))),
            ),
        ],
      ],
    );
  }

  /// "Shares their calendar and 2 lists with you".
  static String _shared(FamilyLink l) {
    final theirs = l.theirs;
    final calendar = theirs.containsKey(Shared.calendar);
    final lists = theirs.keys.where((k) => k != Shared.calendar).length;
    final parts = [
      if (calendar) 'their calendar',
      if (lists == 1) '1 list' else if (lists > 1) '$lists lists',
    ];
    return parts.isEmpty ? 'Linked' : 'Shares ${parts.join(' and ')} with you';
  }
}
