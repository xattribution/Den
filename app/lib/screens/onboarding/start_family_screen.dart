import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../design/parts/family_frame.dart';
import '../../design/parts/family_pickers.dart';
import '../../design/parts/family_words.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';

/// Starting a family: its name and time zone, you (the first parent), and this device. Creating
/// it writes the genesis changes; the router then moves on to "Add people".
class StartFamilyScreen extends StatefulWidget {
  const StartFamilyScreen({super.key, this.initialTimeZone});

  /// Overrides the device's time zone, for tests and screenshots.
  final String? initialTimeZone;

  @override
  State<StartFamilyScreen> createState() => _StartFamilyScreenState();
}

class _StartFamilyScreenState extends State<StartFamilyScreen> {
  final _family = TextEditingController();
  final _name = TextEditingController();
  final _device = TextEditingController();
  Marker _marker = Marker.blue;
  Animal _animal = Animal.cat;
  String _zone = 'UTC';
  DeviceKind? _kind;
  bool _deviceNameEdited = false;
  bool _tried = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialTimeZone != null) {
      _zone = widget.initialTimeZone!;
    } else {
      deviceTimeZone().then((z) {
        if (mounted) setState(() => _zone = z);
      });
    }
    _name.addListener(_suggestDevice);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_kind == null) {
      _kind = guessDeviceKind(context);
      _suggestDevice();
    }
  }

  void _suggestDevice() {
    if (_deviceNameEdited) return;
    _device.text = suggestDeviceName(_name.text, _kind ?? DeviceKind.phone);
  }

  @override
  void dispose() {
    _family.dispose();
    _name.dispose();
    _device.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _tried = true);
    if (_family.text.trim().isEmpty || _name.text.trim().isEmpty) return;
    setState(() => _saving = true);
    final den = context.den;
    final ok = await attempt(
      context,
      () => den.createFamily(
        familyName: _family.text.trim(),
        timezone: _zone,
        yourName: _name.text.trim(),
        marker: _marker,
        animal: _animal,
        deviceName: _device.text.trim().isEmpty ? suggestDeviceName(_name.text, _kind!) : _device.text.trim(),
        deviceKind: _kind!,
      ),
    );
    if (mounted && !ok) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final kind = _kind ?? DeviceKind.phone;
    String? need(TextEditingController t, String message) => _tried && t.text.trim().isEmpty ? message : null;

    return FormFrame(
      title: 'Start a family',
      bottom: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _saving ? null : _create,
          child: Text(_saving ? 'Creating family' : 'Create family'),
        ),
      ),
      children: [
        const SectionHeader('Family'),
        FormBlock(
          top: 0,
          child: TextField(
            controller: _family,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Family name',
              hintText: 'The Riveras',
              errorText: need(_family, 'Add a family name.'),
            ),
            onChanged: (_) {
              if (_tried) setState(() {});
            },
          ),
        ),
        const FormBlock(child: FieldLabel('Time zone')),
        FormBlock(
          top: 0,
          child: TimeZoneField(value: _zone, onChanged: (z) => setState(() => _zone = z)),
        ),
        const SectionHeader('You'),
        FormBlock(
          top: 0,
          child: TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Your name',
              hintText: 'Sam',
              errorText: need(_name, 'Add your name.'),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const FormBlock(
          child: FieldLabel('Your animal', info: 'Your animal and marker are how the family sees you on every screen.'),
        ),
        FormBlock(
          top: 0,
          child: AnimalPicker(value: _animal, marker: _marker, onChanged: (a) => setState(() => _animal = a)),
        ),
        const FormBlock(child: FieldLabel('Your marker')),
        FormBlock(
          top: 0,
          child: MarkerPicker(value: _marker, onChanged: (m) => setState(() => _marker = m)),
        ),
        const SectionHeader('This device'),
        FormBlock(
          top: 0,
          child: TextField(
            controller: _device,
            decoration: const InputDecoration(labelText: 'Device name'),
            onChanged: (_) => _deviceNameEdited = true,
          ),
        ),
        const FormBlock(child: FieldLabel('Kind')),
        FormBlock(
          top: 0,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Segmented<DeviceKind>(
                options: {for (final k in personalKinds) k: FamilyWords.deviceKind(k)},
                value: kind,
                onChanged: (k) => setState(() {
                  _kind = k;
                  _suggestDevice();
                }),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
