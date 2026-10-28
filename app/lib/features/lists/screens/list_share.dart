import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../design/tokens.dart';
import '../words/list_words.dart';

/// Shares a list's open items as text: a QR code to scan from another phone, copy, or the
/// system share sheet.
Future<void> showShareSheet(BuildContext context, ListState lv) {
  return showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _ShareSheet(lv));
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet(this.lv);
  final ListState lv;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = shareText(widget.lv);
    final empty = widget.lv.open == 0;
    // A QR code reads best dark on light in any theme, so it always uses the day tokens.
    const qrInk = DenColors.day;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(header: true, child: Text('Share ${widget.lv.list.title}', style: context.type.title(c.ink))),
            const SizedBox(height: Sp.l),
            if (empty)
              Text('Nothing to share. Every item on this list is done.', style: context.type.body(c.ink2))
            else ...[
              Center(
                child: Container(
                  padding: const EdgeInsets.all(Sp.m),
                  decoration: BoxDecoration(
                    color: qrInk.paper,
                    borderRadius: BorderRadius.circular(Radii.control),
                    border: Border.all(color: c.rule),
                  ),
                  child: QrImageView(
                    data: text,
                    size: 220,
                    padding: EdgeInsets.zero,
                    backgroundColor: qrInk.paper,
                    eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: qrInk.ink),
                    dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: qrInk.ink),
                    semanticsLabel: 'QR code with the open items of ${widget.lv.list.title}',
                    errorStateBuilder: (context, _) => SizedBox.square(
                      dimension: 220,
                      child: Center(
                        child: Text(
                          'Too long for a QR code. Copy or share the list instead.',
                          textAlign: TextAlign.center,
                          style: context.type.body(qrInk.ink2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Sp.l),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: text));
                        if (mounted) setState(() => _copied = true);
                      },
                      icon: Icon(_copied ? PhosphorIconsBold.check : PhosphorIconsRegular.copy, size: 18),
                      label: Text(_copied ? 'Copied' : 'Copy list'),
                    ),
                  ),
                  const SizedBox(width: Sp.s),
                  Expanded(
                    child: Builder(
                      builder: (buttonContext) => FilledButton.icon(
                        onPressed: () {
                          final box = buttonContext.findRenderObject() as RenderBox?;
                          SharePlus.instance.share(
                            ShareParams(
                              text: text,
                              subject: widget.lv.list.title,
                              sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
                            ),
                          );
                        },
                        icon: const Icon(PhosphorIconsRegular.shareFat, size: 18),
                        label: const Text('Share list'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
