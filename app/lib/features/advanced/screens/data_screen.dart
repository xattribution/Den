import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/widgets.dart';
import '../state/export.dart';

/// Advanced → Data: everything this device holds as a file, and the history of every change
/// with who made it and what it was before.
class DataScreen extends StatelessWidget {
  const DataScreen({super.key});

  @override
  Widget build(BuildContext context) => DenPage(
        title: 'Data',
        children: [
          GroupCard(
            child: Column(
              children: ruled([
                NavRow(
                  icon: PhosphorIconsRegular.clockCounterClockwise,
                  label: 'History',
                  detail: 'Every change, who made it, and what it was before',
                  onTap: () => context.push('/history'),
                ),
                NavRow(
                  icon: PhosphorIconsRegular.fileArrowDown,
                  label: 'Export everything',
                  detail: 'A file with all the family’s records on this device',
                  chevron: false,
                  onTap: () => exportFamilyJson(context),
                ),
              ], indent: 36),
            ),
          ),
        ],
      );
}
