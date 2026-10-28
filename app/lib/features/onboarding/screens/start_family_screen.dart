import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../design/forms/frame.dart';
import '../../../design/pickers/family_pickers.dart';
import '../../family/words/family_words.dart';
import '../../../design/pickers/picture_picker.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/pairing.dart';
import '../../../app/app_state.dart';
import '../../../platform/capabilities.dart';

/// Starting a family: its name and time zone, you (the first parent), and this device. Creating
/// it writes the genesis changes; the router then moves on to "Add people".
///
/// In a browser served by a fresh hub, the hub's setup code goes here too: once the family
/// exists, this browser takes the hub in (see [PairingService.adoptServingHub]) while "Add
/// people" shows how that goes.
class StartFamilyScreen extends StatefulWidget {
  const StartFamilyScreen({super.key, this.initialTimeZone, this.hub});

  /// Overrides the device's time zone, for tests and screenshots.
  final String? initialTimeZone;

  /// The fresh hub that served this page, for tests; by default asked of the hub on the web.
  final HubInfo? hub;

  @override
  State<StartFamilyScreen> createState() => _StartFamilyScreenState();
}

class _StartFamilyScreenState extends State<StartFamilyScreen> {
  final _family = TextEditingController();
  final _name = TextEditingController();
  final _device = TextEditingController();
  final _code = TextEditingController();
  HubInfo? _hub;
  bool _askedHub = false;
  Marker _marker = Marker.sky;
  String _picture = Picture.initial;
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
    if (!_askedHub) {
      _askedHub = true;
      _hub = widget.hub;
      if (_hub == null && Capabilities.web) {
        Pairing.of(context).servingHub().then((hub) {
          if (mounted) setState(() => _hub = hub);
        });
      }
    }
  }

  /// A fresh hub this browser can take in with its setup code.
  bool get _adopting {
    final hub = _hub;
    return hub != null && !hub.paired && hub.stage == 'waiting_for_code';
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
    _code.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _tried = true);
    if (_family.text.trim().isEmpty || _name.text.trim().isEmpty) return;
    final hub = _adopting ? _hub : null;
    final code = _code.text.trim();
    if (hub != null && code.isEmpty) return;
    setState(() => _saving = true);
    final den = context.den;
    final pairing = Pairing.of(context);
    final ok = await attempt(
      context,
      () => den.createFamily(
        familyName: _family.text.trim(),
        timezone: _zone,
        yourName: _name.text.trim(),
        marker: _marker,
        picture: _picture,
        deviceName: _device.text.trim().isEmpty ? suggestDeviceName(_name.text, _kind!) : _device.text.trim(),
        deviceKind: _kind!,
      ),
    );
    if (ok && hub != null) {
      // The router has already moved on to Add people, which follows this.
      try {
        Pairing.adoption.value = pairing.adoptServingHub(hub, code);
      } on PairingException {
        Pairing.adoption.value = null;
      }
    }
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
        const FormBlock(child: FieldLabel('Your picture')),
        FormBlock(
          top: 0,
          child: PicturePicker(
            name: _name.text.trim().isEmpty ? 'You' : _name.text.trim(),
            picture: _picture,
            color: _marker,
            colorLabel: 'Your color',
            onPicture: (p) => setState(() => _picture = p),
            onColor: (m) => setState(() => _marker = m),
          ),
        ),
        if (_adopting) ...[
          InfoHeader(
            'Your hub',
            info: 'The hub printed a setup code when it started, like ABCD-EFGH. '
                "Whoever set up ${_hub!.name} can find it in the hub's log.",
          ),
          FormBlock(
            top: 0,
            child: TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Setup code',
                hintText: 'ABCD-EFGH',
                errorText: need(_code, "Add the hub's setup code."),
              ),
              onChanged: (_) {
                if (_tried) setState(() {});
              },
            ),
          ),
        ],
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
