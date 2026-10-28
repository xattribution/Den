import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/pickers/picture_picker.dart';
import '../../../design/pickers/time_zone_picker.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/pairing.dart';
import '../../../platform/time_zone.dart';
import '../state/onboarding_actions.dart';
import '../state/this_device.dart';

/// Starting a family: its name and time zone, and you (the first parent) with your picture.
/// This device's name and kind come from what it is ("Sam's iPhone"). Creating it writes the
/// genesis changes; the router then moves on to "Add people".
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
  final _code = TextEditingController();
  HubInfo? _hub;
  bool _askedHub = false;
  Marker _marker = Marker.sky;
  String _picture = Picture.initial;
  String _zone = 'UTC';
  DeviceKind? _kind;
  bool _tried = false;
  bool _saving = false;
  String? _error;

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
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _kind ??= guessDeviceKind(context);
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

  @override
  void dispose() {
    _family.dispose();
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _tried = true);
    if (_family.text.trim().isEmpty || _name.text.trim().isEmpty) return;
    final hub = _adopting ? _hub : null;
    final code = _code.text.trim();
    if (hub != null && code.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final onboarding = context.onboardingActions;
    final pairing = Pairing.of(context);
    final problem = await tryWrite(
      () => onboarding.foundFamily(
        familyName: _family.text.trim(),
        timezone: _zone,
        yourName: _name.text.trim(),
        marker: _marker,
        picture: _picture,
        deviceName: suggestDeviceName(_name.text, _kind!),
        deviceKind: _kind!,
      ),
    );
    if (problem == null && hub != null) {
      // The router has already moved on to Add people, which follows this.
      try {
        Pairing.adoption.value = pairing.adoptServingHub(hub, code);
      } on PairingException {
        Pairing.adoption.value = null;
      }
    }
    if (mounted && problem != null) {
      setState(() {
        _saving = false;
        _error = problem;
      });
    }
  }

  Future<void> _pickPicture() => showDenSheet<void>(
        context,
        builder: (sheet) => StatefulBuilder(
          builder: (sheet, setSheet) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, Sp.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetHeader(title: 'Your picture', actionLabel: 'Done', primary: true),
                PicturePicker(
                  name: _name.text.trim().isEmpty ? 'You' : _name.text.trim(),
                  picture: _picture,
                  color: _marker,
                  colorLabel: 'Your color',
                  onPicture: (p) {
                    setState(() => _picture = p);
                    setSheet(() {});
                  },
                  onColor: (m) {
                    setState(() => _marker = m);
                    setSheet(() {});
                  },
                ),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    String? need(TextEditingController field, String message) => _tried && field.text.trim().isEmpty ? message : null;
    final name = _name.text.trim();
    final color = PersonColor.forMarker(_marker).color;

    return DenPage(
      title: 'Start a family',
      bottom: FilledButton(
        onPressed: _saving ? null : _create,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(_saving ? 'Creating the family' : 'Create family'),
      ),
      children: [
        LabeledField(
          label: 'Family name',
          error: need(_family, 'Add a family name.'),
          child: TextField(
            controller: _family,
            textCapitalization: TextCapitalization.words,
            style: t.body(c.ink),
            decoration: const InputDecoration(hintText: 'The Riveras'),
            onChanged: (_) {
              if (_tried) setState(() {});
            },
          ),
        ),
        GroupCard(
          child: NavRow(
            icon: PhosphorIconsRegular.globeHemisphereWest,
            label: 'Time zone',
            value: zoneLabel(_zone),
            onTap: () async {
              final zone = await showTimeZoneSheet(context, _zone);
              if (zone != null && mounted) setState(() => _zone = zone);
            },
          ),
        ),
        LabeledField(
          label: 'Your name',
          error: need(_name, 'Add your name.'),
          child: TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            style: t.body(c.ink),
            decoration: const InputDecoration(hintText: 'Sam'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        GroupCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.m),
            child: Row(
              children: [
                _picture == Picture.initial
                    ? DenAvatar.initial(name.isEmpty ? '?' : name, color: color, size: 56, semanticLabel: 'Your picture')
                    : DenAvatar.picture(_picture, color: color, size: 56, semanticLabel: 'Your picture'),
                const SizedBox(width: Sp.m),
                Expanded(child: Text('Your picture and color', style: t.body(c.ink))),
                const SizedBox(width: Sp.s),
                OutlinedButton(onPressed: _pickPicture, child: const Text('Change')),
              ],
            ),
          ),
        ),
        if (_adopting)
          LabeledField(
            label: 'Setup code for ${_hub!.name}, from the hub\'s log',
            error: need(_code, "Add the hub's setup code."),
            child: TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              enableSuggestions: false,
              style: t.body(c.ink),
              decoration: const InputDecoration(hintText: 'ABCD-EFGH'),
              onChanged: (_) {
                if (_tried) setState(() {});
              },
            ),
          ),
        if (_error != null) ErrorState(message: _error!, actionLabel: 'Try again', onAction: _create),
      ],
    );
  }
}
