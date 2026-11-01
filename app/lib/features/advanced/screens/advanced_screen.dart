import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../app/build_info.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/web/web_app.dart';

/// Settings → Advanced, for parents: what someone sets up once and the family never sees in
/// daily use. The hub and sync, assistants and automations, Home Assistant, signing in with
/// Google or Apple, and the family's data; and Show screen info, for reporting a problem with the screen. The kitchen screen is on
/// Settings itself, where a parent looks for it.
class AdvancedScreen extends StatelessWidget {
  const AdvancedScreen({super.key, this.web});

  /// Shows what a browser shows, for tests; by default only on the web.
  final bool? web;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.connection, Changes.prefs});
    final web = this.web ?? Capabilities.web;
    final den = app.den;
    if (!app.allows(DenAction.manageFamily)) {
      return const DenPage(title: 'Advanced', children: [EmptyState(message: 'Only parents can open Advanced.')]);
    }
    final connected = den.connections.where((x) => x.status == ConnectionStatus.active).length;
    final waiting = den.connections.where((x) => x.status == ConnectionStatus.pending).length;
    return DenPage(
      title: 'Advanced',
      children: [
        if (!app.allowsTrust(DenAction.manageFamily))
          const NoticeLine(
            icon: PhosphorIconsRegular.lockKey,
            message: "Devices and connections change only on a parent's own phone, not on a shared screen.",
          ),
        GroupCard(
          child: Column(
            children: ruled([
              NavRow(
                icon: PhosphorIconsRegular.hardDrives,
                label: 'Hub and sync',
                detail: 'Keeping every device up to date',
                onTap: () => context.push('/settings/advanced/hub'),
              ),
              NavRow(
                icon: PhosphorIconsRegular.plugsConnected,
                label: 'AI and automations',
                value: waiting > 0 ? '$waiting waiting' : (connected == 0 ? 'None' : '$connected connected'),
                onTap: () => context.push('/settings/connections'),
              ),
              NavRow(
                icon: PhosphorIconsRegular.houseLine,
                label: 'Home Assistant',
                onTap: () => context.push('/settings/home-assistant'),
              ),
              NavRow(
                icon: PhosphorIconsRegular.signIn,
                label: 'Sign in with Google or Apple',
                detail: 'Parents sign in to Den in a browser',
                onTap: () => context.push('/settings/advanced/sign-in'),
              ),
              NavRow(
                icon: PhosphorIconsRegular.database,
                label: 'Data',
                detail: 'Export, and the history of changes',
                onTap: () => context.push('/settings/advanced/data'),
              ),
            ], indent: 36),
          ),
        ),
        DenSection(
          title: 'When something looks wrong',
          child: Column(
            children: ruled([
              SwitchLine(
                label: 'Show screen info',
                detail: 'Sizes, the keyboard and the last few screen events, over the app. Take a screenshot when '
                    'something looks wrong.',
                value: app.device.screenInfo,
                onChanged: (on) => app.device.screenInfo = on,
              ),
              if (web && app.device.screenInfo)
                NavRow(
                  icon: PhosphorIconsRegular.copy,
                  label: 'Copy screen info',
                  detail: 'To paste into a message',
                  chevron: false,
                  onTap: () => WebApp.copy(screenInfoText()),
                ),
            ], indent: 36),
          ),
        ),
      ],
    );
  }
}

/// What Copy screen info copies: this build and what the page says about the screen, as JSON.
String screenInfoText() => const JsonEncoder.withIndent(' ').convert({
      'build': DenBuild.label,
      ...?WebApp.screenInfo(),
    });
