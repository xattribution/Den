import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/widgets.dart';
import '../../family/family.dart';

/// Settings → Advanced, for parents: what someone sets up once and the family never sees in
/// daily use. The hub and sync, shared displays, assistants and automations, Home Assistant,
/// and the family's data.
class AdvancedScreen extends StatelessWidget {
  const AdvancedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.connection});
    final den = app.den;
    if (!app.allows(DenAction.manageFamily)) {
      return const DenPage(title: 'Advanced', children: [EmptyState(message: 'Only parents can open Advanced.')]);
    }
    final displays = sharedDisplays(den).length;
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
                icon: PhosphorIconsRegular.monitor,
                label: 'Shared displays',
                value: displays == 0 ? 'None' : '$displays',
                onTap: () => context.push('/settings/advanced/displays'),
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
                icon: PhosphorIconsRegular.database,
                label: 'Data',
                detail: 'Export, and the history of changes',
                onTap: () => context.push('/settings/advanced/data'),
              ),
            ], indent: 36),
          ),
        ),
      ],
    );
  }
}
