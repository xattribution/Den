import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:timezone/timezone.dart' as tz;

import '../tokens.dart';

/// Common US zones first, in the words families use.
const Map<String, String> commonZones = {
  'America/New_York': 'Eastern Time',
  'America/Chicago': 'Central Time',
  'America/Denver': 'Mountain Time',
  'America/Phoenix': 'Arizona',
  'America/Los_Angeles': 'Pacific Time',
  'America/Anchorage': 'Alaska',
  'Pacific/Honolulu': 'Hawaii',
};

/// "Central Time · Chicago", or "Lisbon · Europe" for zones outside the common list.
String zoneLabel(String iana) {
  final parts = iana.split('/');
  final city = parts.last.replaceAll('_', ' ');
  final common = commonZones[iana];
  if (common != null) return '$common · $city';
  if (parts.length < 2) return iana;
  return '$city · ${parts.first.replaceAll('_', ' ')}';
}

/// Shows the family's time zone; tapping opens a searchable list.
class TimeZoneField extends StatelessWidget {
  const TimeZoneField({super.key, required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.well,
      borderRadius: BorderRadius.circular(Radii.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: () async {
          final picked = await showTimeZoneSheet(context, value);
          if (picked != null) onChanged(picked);
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: Targets.adult),
          padding: const EdgeInsets.symmetric(horizontal: Sp.m),
          child: Row(
            children: [
              Expanded(child: Text(zoneLabel(value), style: context.type.body(c.ink))),
              Text('Change', style: context.type.bodyStrong(c.ink)),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String?> showTimeZoneSheet(BuildContext context, String current) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => FractionallySizedBox(heightFactor: 0.85, child: _ZoneSheet(current: current)),
  );
}

class _ZoneSheet extends StatefulWidget {
  const _ZoneSheet({required this.current});
  final String current;

  @override
  State<_ZoneSheet> createState() => _ZoneSheetState();
}

class _ZoneSheetState extends State<_ZoneSheet> {
  String _query = '';

  late final List<String> _all = () {
    final names = tz.timeZoneDatabase.locations.keys
        .where((n) => n.contains('/') && !n.startsWith('Etc/') && !commonZones.containsKey(n))
        .toList()
      ..sort();
    return [...commonZones.keys, ...names];
  }();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty ? _all : _all.where((n) => zoneLabel(n).toLowerCase().contains(q) || n.toLowerCase().contains(q)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.s),
          child: Text('Time zone', style: context.type.title(c.ink)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.s),
          child: TextField(
            autofocus: false,
            decoration: const InputDecoration(hintText: 'Search cities', prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass)),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (context, i) {
              final name = shown[i];
              final selected = name == widget.current;
              return ListTile(
                title: Text(zoneLabel(name)),
                selected: selected,
                selectedColor: c.ink,
                trailing: selected ? Icon(PhosphorIconsBold.check, color: c.ink, size: 18) : null,
                onTap: () => Navigator.of(context).pop(name),
              );
            },
          ),
        ),
      ],
    );
  }
}
