import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import 'export_save_stub.dart' if (dart.library.io) 'export_save_io.dart';

/// Exports every record this device holds as JSON: saved to Downloads on a computer, handed to
/// the share sheet on phones, tablets and browsers.
Future<void> exportFamilyJson(BuildContext context) async {
  final app = context.app;
  final json = const JsonEncoder.withIndent('  ').convert(app.den.exportJson());
  final bytes = utf8.encode(json);
  final name = 'den-${app.today}.json';
  try {
    final folder = kIsWeb ? null : await saveExportToDisk(name, bytes);
    if (folder != null) {
      if (context.mounted) showNote(context, 'Saved $name in $folder.');
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(Uint8List.fromList(bytes), mimeType: 'application/json', name: name)],
        fileNameOverrides: [name],
        subject: name,
      ),
    );
  } on Object catch (e) {
    if (context.mounted) showNote(context, "Couldn't export: $e. Try again, or copy the data from another device.");
  }
}

bool _licensesAdded = false;

/// Adds the bundled typeface's SIL Open Font License to the app's licenses page.
void registerFontLicense() {
  if (_licensesAdded) return;
  _licensesAdded = true;
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['Atkinson Hyperlegible Next'], text);
  });
}
