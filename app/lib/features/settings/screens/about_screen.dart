import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../app/build_info.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/web/web_app.dart';
import '../../advanced/advanced.dart' show registerFontLicense;

/// Settings → About: the version, the build (its commit and when it was built), in a browser the
/// build the hub serves now, and the licenses.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, this.version, this.web, this.hub});

  /// Overrides the version read from the platform, for tests.
  final String? version;

  /// Shows what a browser shows, for tests; by default only on the web.
  final bool? web;

  /// What the hub serves, for tests; by default its `build.json` and `/health`, in a browser.
  final Future<HubBuild?> Function()? hub;

  /// What the hub this page came from serves now: the build its Dockerfile wrote down and the
  /// version its health check reports.
  static Future<HubBuild?> hubBuild() async {
    final answers = await Future.wait([WebApp.fetchFresh('build.json'), WebApp.fetchFresh('health')]);
    return HubBuild.parse(build: answers[0], health: answers[1]);
  }

  /// What a hub serving another build than this one asks for.
  static const String newerWaiting = 'A newer Den is waiting. It opens the next time Den starts: close Den and open it again.';

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String? _version;
  HubBuild? _hub;

  @override
  void initState() {
    super.initState();
    registerFontLicense();
    _version = widget.version;
    if (_version == null) {
      PackageInfo.fromPlatform()
          .then((info) {
            if (mounted) setState(() => _version = info.version);
          })
          .catchError((Object _) {});
    }
    if (widget.hub != null || (widget.web ?? Capabilities.web)) {
      (widget.hub ?? AboutScreen.hubBuild)()
          .then((hub) {
            if (mounted) setState(() => _hub = hub);
          })
          .catchError((Object _) {});
    }
  }

  @override
  Widget build(BuildContext context) => DenPage(
        title: 'About',
        children: [
          GroupCard(
            child: Column(
              children: ruled([
                _Fact(label: 'Version', value: _version ?? ''),
                _Fact(label: 'Build', value: DenBuild.label),
                if (_hub case final hub?)
                  _Fact(
                    label: 'On the hub',
                    value: hub.label,
                    note: hub.differsFrom(DenBuild.commit) ? AboutScreen.newerWaiting : null,
                  ),
                NavRow(
                  label: 'Licenses',
                  onTap: () => showLicensePage(context: context, applicationName: 'Den', applicationVersion: _version),
                ),
              ]),
            ),
          ),
        ],
      );
}

/// A fact about this device, read-only: its label and value (wrapping at the end when long),
/// and a [note] under them.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.note});

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return MergeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.s),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: t.body(c.ink)),
                  const SizedBox(width: Sp.m),
                  Expanded(child: Text(value, style: t.meta(c.ink2), textAlign: TextAlign.end)),
                ],
              ),
              if (note != null) ...[
                const SizedBox(height: Sp.xs),
                Text(note!, style: t.meta(c.ink2)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
