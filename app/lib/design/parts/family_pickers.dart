import 'package:den_core/den_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:timezone/timezone.dart' as tz;

import '../tokens.dart';
import '../../web/web_app.dart';
import '../widgets.dart';
import 'family_words.dart';

/// A form label in meta type, with an optional (i).
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.info, this.trailing});

  final String text;
  final String? info;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.s),
      child: Row(
        children: [
          Text(text, style: context.type.meta(c.ink2)),
          if (info != null) InfoTip(info!),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------------------- time zones

/// Common US zones first, in the words families use.
const Map<String, String> _commonZones = {
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
  final common = _commonZones[iana];
  if (common != null) return '$common · $city';
  if (parts.length < 2) return iana;
  return '$city · ${parts.first.replaceAll('_', ' ')}';
}

/// This device's IANA time zone, or a best guess from its UTC offset, or UTC.
Future<String> deviceTimeZone() async {
  try {
    final info = await FlutterTimezone.getLocalTimezone();
    if (tz.timeZoneDatabase.locations.containsKey(info.identifier)) return info.identifier;
  } on Object catch (e) {
    debugPrint('Time zone lookup failed: $e');
  }
  final offset = DateTime.now().timeZoneOffset;
  final now = DateTime.now().millisecondsSinceEpoch;
  for (final name in _commonZones.keys) {
    final loc = tz.timeZoneDatabase.locations[name];
    if (loc != null && loc.timeZone(now).offset == offset) return name;
  }
  return 'UTC';
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
        .where((n) => n.contains('/') && !n.startsWith('Etc/') && !_commonZones.containsKey(n))
        .toList()
      ..sort();
    return [..._commonZones.keys, ...names];
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

// ------------------------------------------------------------------------------- this device

/// The kinds a person picks for the device in their hand; hubs and displays are chosen by mode.
const personalKinds = [DeviceKind.phone, DeviceKind.tablet, DeviceKind.desktop, DeviceKind.browser];

/// A sensible kind for the device the app is running on.
DeviceKind guessDeviceKind(BuildContext context) {
  if (kIsWeb) return WebApp.info.kind;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return MediaQuery.sizeOf(context).shortestSide >= 600 ? DeviceKind.tablet : DeviceKind.phone;
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return DeviceKind.desktop;
  }
}

/// "Sam's phone", from a person's name and the device kind ("Sam's iPhone" in Safari on one).
String suggestDeviceName(String personName, DeviceKind kind) {
  final apple = kIsWeb && WebApp.info.ios;
  final word = switch (kind) {
    DeviceKind.phone => apple ? 'iPhone' : 'phone',
    DeviceKind.tablet => apple ? 'iPad' : 'tablet',
    DeviceKind.desktop => 'computer',
    DeviceKind.browser => 'browser',
    DeviceKind.hub => 'hub',
    DeviceKind.display => 'display',
  };
  final name = personName.trim();
  if (name.isEmpty) return apple && (kind == DeviceKind.phone || kind == DeviceKind.tablet) ? word : FamilyWords.deviceKind(kind);
  return '${FamilyWords.possessive(name)} $word';
}

/// Whether this platform can scan a QR code with its camera.
bool get canScanQr => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
