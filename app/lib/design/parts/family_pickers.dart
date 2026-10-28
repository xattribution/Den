import 'package:den_core/den_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:timezone/timezone.dart' as tz;

import '../pictograms.dart';
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

/// The chosen-state ring around a round choice: an ink ring with a paper gap, so the choice reads
/// without relying on its color.
class _ChoiceRing extends StatelessWidget {
  const _ChoiceRing({required this.selected, required this.child});
  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedContainer(
      duration: Motion.of(context, Motion.state),
      curve: Motion.curve,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: selected ? c.ink : Colors.transparent, width: 2.5),
      ),
      child: child,
    );
  }
}

/// The nine animals on the person's marker, as their avatar will look. The chosen one has an
/// ink ring.
class AnimalPicker extends StatelessWidget {
  const AnimalPicker({super.key, required this.value, required this.marker, required this.onChanged, this.size = 48});

  final Animal value;
  final Marker marker;
  final ValueChanged<Animal> onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Wrap(
      spacing: Sp.xs,
      runSpacing: Sp.xs,
      children: [
        for (final a in Animal.values)
          Semantics(
            label: FamilyWords.animal(a),
            selected: a == value,
            button: true,
            child: Tooltip(
              message: FamilyWords.animal(a),
              child: InkResponse(
                onTap: () => onChanged(a),
                radius: size / 2 + 6,
                child: _ChoiceRing(
                  selected: a == value,
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(color: c.marker(marker), shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Icon(Pictograms.animal(a), size: size * 0.58, color: c.onMarker),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The ten marker swatches: the one place hues appear as choices. The chosen swatch carries a
/// check and an ink ring; a marker someone else already uses shows their animal, so two people
/// don't end up writing in the same color by accident.
class MarkerPicker extends StatelessWidget {
  const MarkerPicker({super.key, required this.value, required this.onChanged, this.takenBy = const {}, this.size = 40});

  final Marker value;
  final ValueChanged<Marker> onChanged;

  /// Markers other people use, with who uses them.
  final Map<Marker, Member> takenBy;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Wrap(
      spacing: Sp.xs,
      runSpacing: Sp.xs,
      children: [
        for (final m in Marker.values)
          Semantics(
            label: takenBy[m] == null ? FamilyWords.marker(m) : '${FamilyWords.marker(m)}, used by ${takenBy[m]!.name}',
            selected: m == value,
            button: true,
            child: Tooltip(
              message: takenBy[m] == null ? FamilyWords.marker(m) : '${FamilyWords.marker(m)} · ${takenBy[m]!.name}',
              child: InkResponse(
                onTap: () => onChanged(m),
                radius: size / 2 + 6,
                child: _ChoiceRing(
                  selected: m == value,
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(color: c.marker(m), shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: m == value
                        ? Icon(PhosphorIconsBold.check, size: size * 0.5, color: c.onMarker)
                        : takenBy[m] != null
                            ? Icon(Pictograms.animal(takenBy[m]!.animal), size: size * 0.5, color: c.onMarker)
                            : null,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Markers already used by anyone except [except].
Map<Marker, Member> markersTaken(Iterable<Member> members, {String? except}) => {
      for (final m in members)
        if (m.id != except) m.marker: m,
    };

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
