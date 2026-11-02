import 'package:den_net/den_net.dart' show DenLink, DenLinkKind;
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/web/handoff.dart';
import '../../../platform/web/web_app.dart';

/// Safari on an iPhone or iPad: put Den on the Home Screen first. The Home Screen app keeps its
/// own storage, apart from Safari's, so a family started or joined in Safari wouldn't be there,
/// and only the Home Screen app can show reminders.
///
/// Opened from an invite or setup [link], it keeps the link for the Home Screen app (see
/// [Handoff]), which picks it up by itself on its first start, and offers Copy invite in one quiet
/// line over the steps for someone who has Den on the Home Screen already: a tapped link always
/// opens Safari, never the Home Screen app. The link's words (or setup code) stay at hand below, for typing.
class HomeScreenSteps extends StatefulWidget {
  const HomeScreenSteps({super.key, this.ipad = false, this.code, this.link});

  /// iPad Safari keeps Share at the top.
  final bool ipad;

  /// Words to show for typing after the move, when there's no [link] (a recovery code).
  final String? code;

  /// The invite or setup link this page was opened with.
  final DenLink? link;

  @override
  State<HomeScreenSteps> createState() => _HomeScreenStepsState();
}

class _HomeScreenStepsState extends State<HomeScreenSteps> {
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    final link = widget.link;
    if (link != null) Handoff.keep(link.route);
  }

  /// Copies the whole link. Called straight from the tap, so the browser lets it.
  Future<void> _copy(DenLink link) async {
    final text = link.hub != null ? link.link().toString() : '${Uri.base.origin}/#${link.route}';
    final copied = await WebApp.copy(text);
    if (mounted) setState(() => _copied = copied);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final link = widget.link;
    final setup = link?.kind == DenLinkKind.setup;
    final typed = link == null ? widget.code : (setup ? link.code : link.words);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One quiet line under the page's heading for whoever has Den already: most people here
        // don't, so the steps are the page.
        if (link != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Sp.xs,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _copied
                        ? (setup ? 'Copied. Open Den and tap Paste a link.' : 'Copied. Open Den and tap Paste an invite.')
                        : 'Already have Den on this ${widget.ipad ? 'iPad' : 'iPhone'}?',
                    style: t.meta(c.ink2),
                  ),
                ),
                if (!_copied)
                  TextButton(
                    onPressed: () => _copy(link),
                    child: Text(setup ? 'Copy link' : 'Copy invite', maxLines: 1, softWrap: false),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Sp.l),
        ],
        DenSection(
          title: 'Add Den to your Home Screen',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: Sp.m),
              ShareButtonPicture(ipad: widget.ipad),
              NumberedSteps(steps: [
                widget.ipad
                    ? 'Tap Share at the top of Safari.'
                    : "Tap Share at the bottom of Safari. If you don't see it, tap the three dots first.",
                'Tap Add to Home Screen, then Add.',
                'Open Den from your Home Screen.',
              ]),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.m, DenLayout.headingInset, 0),
          child: Text(
            link == null
                ? 'From the Home Screen, Den opens like an app, works without a connection and can send reminders.'
                : setup
                    ? 'Den picks up this link there by itself, and starts your family.'
                    : 'Den picks up this invite there by itself.',
            style: t.meta(c.ink2),
          ),
        ),
        if (typed != null) ...[
          const SizedBox(height: DenLayout.sectionGap),
          DenSection(
            title: setup ? 'If Den asks for the setup code' : (link == null ? 'Then type this code' : 'If Den asks for words'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.l),
              child: SelectableText(typed, style: t.sheetTitle(c.ink).copyWith(fontSize: 24)),
            ),
          ),
        ],
      ],
    );
  }
}

/// Where Add to Home Screen is in Safari, drawn the way Safari draws it: More (the three dots,
/// on an iPhone's compact bar), Share, then Add to Home Screen.
class ShareButtonPicture extends StatelessWidget {
  const ShareButtonPicture({super.key, this.ipad = false});

  final bool ipad;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    Widget part(IconData icon, String label, {bool strong = false}) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: strong ? c.ink : c.bg,
                borderRadius: BorderRadius.circular(Radii.tile),
              ),
              child: Icon(icon, size: 26, color: strong ? c.onPrimary : c.ink),
            ),
            const SizedBox(height: Sp.xs),
            Text(label, style: t.meta(c.ink), textAlign: TextAlign.center),
          ],
        );
    Widget arrow() => Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: Icon(PhosphorIconsRegular.caretRight, size: 18, color: c.ink3),
        );
    return Semantics(
      label: ipad ? 'Share, then Add to Home Screen' : 'More, then Share, then Add to Home Screen',
      excludeSemantics: true,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: Sp.s,
        runSpacing: Sp.s,
        children: [
          if (!ipad) ...[part(PhosphorIconsBold.dotsThree, 'More'), arrow()],
          part(PhosphorIconsRegular.export, 'Share', strong: true),
          arrow(),
          part(PhosphorIconsRegular.plusSquare, 'Add to Home Screen'),
        ],
      ),
    );
  }
}
