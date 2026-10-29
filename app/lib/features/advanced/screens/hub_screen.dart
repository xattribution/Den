import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../widgets/device_sync.dart';
import '../widgets/hubs_section.dart';

/// Advanced → Hub and sync: how this device syncs, the family's hubs (with Remove), and adding
/// devices the plumbing way (a hub with its setup code, a browser on a computer, a device in the
/// same room). People join with an invite from their page in Family instead.
class HubScreen extends StatelessWidget {
  const HubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final trust = app.allowsTrust(DenAction.manageFamily);
    final hubs = app.network?.hubDevices ??
        app.den.devices.where((d) => d.mode == DeviceMode.hub && d.approved && !d.revoked).toList();
    // "Another hub" also when this device is the family's hub.
    final hub = hubs.firstOrNull ?? (app.network?.isHub ?? false ? app.den.thisDevice : null);
    return DenPage(
      title: 'Hub and sync',
      children: [
        const DeviceSyncSection(),
        if (app.network != null && hubs.isNotEmpty) const HubsSection(),
        DenSection(
          title: 'Add a device',
          child: Column(
            children: ruled([
              NavRow(
                icon: PhosphorIconsRegular.hardDrives,
                label: hub == null ? 'A hub' : 'Another hub',
                detail: hub == null ? 'A NAS, a Raspberry Pi or a computer that stays on' : 'The family syncs through ${hub.name}',
                onTap: trust ? () => context.push('/settings/advanced/hub/add') : null,
              ),
              NavRow(
                icon: PhosphorIconsRegular.browser,
                label: 'A browser on a computer',
                onTap: trust ? () => context.push('/settings/advanced/hub/browser') : null,
              ),
              if (!Capabilities.web)
                NavRow(
                  icon: PhosphorIconsRegular.deviceTablet,
                  label: 'A device in the same room',
                  detail: 'With a code to scan or four words to read out',
                  onTap: trust ? () => context.push('/settings/advanced/hub/nearby') : null,
                ),
            ], indent: 36),
          ),
        ),
        if (!trust) const NoticeLine(icon: PhosphorIconsRegular.lockKey, message: "Devices are added on a parent's own phone."),
      ],
    );
  }
}
