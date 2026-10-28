import 'package:flutter/material.dart';

import '../motion.dart';
import '../tokens.dart';
import '../words.dart';

/// A setting as a sentence and a switch (Family.dc.html's parent controls): what on means
/// ("Can add to lists"), a quieter line under it ("Groceries and packing lists"), and the switch
/// at the end. The whole row flips it. 64 tall at least, inside a section's card.
///
/// [onChanged] null keeps it visible and unchangeable, with [reason] saying why in place of the
/// detail ("Change this on your own phone").
class SwitchLine extends StatelessWidget {
  const SwitchLine({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.detail,
    this.reason,
    this.leading,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? detail;

  /// Why it can't be changed now, shown when [onChanged] is null.
  final String? reason;

  /// A face (32 or 40) before the words, for a switch about a person.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final enabled = onChanged != null;
    final under = !enabled && reason != null ? reason : detail;
    return MergeSemantics(
      child: DenPressable(
        onTap: enabled ? () => onChanged!(!value) : null,
        scale: false,
        shape: const RoundedRectangleBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.s + 2),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: Sp.m)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tidy(label), style: t.body(enabled ? c.ink : c.ink2)),
                      if (under != null && under.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(tidy(under), style: t.meta(c.ink2)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: Sp.m),
                Switch(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
