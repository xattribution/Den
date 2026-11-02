import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show DenLink, DenLinkKind;
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
import '../../../platform/sync/server_setup.dart';
import '../../../platform/time_zone.dart';
import '../../../platform/web/web_app.dart';
import '../state/onboarding_actions.dart';
import '../state/this_device.dart';
import 'first_boot_screen.dart';
import 'home_screen_steps.dart';

/// Starting a family: its name and time zone, and you (the first parent) with your picture.
/// This device's name and kind come from what it is ("Sam's iPhone"). Creating it writes the
/// genesis changes; the router then moves on to "Add people".
///
/// In a browser served by a fresh hub, the hub's setup code goes here too: once the family
/// exists, this browser takes the hub in (see [PairingService.adoptServingHub]) while "Add
/// people" shows how that goes. Opened from the hub's setup link (`den_hub setup-link`), the
/// link brings the code and the hub's device id, so there's nothing to type and no words to
/// compare: only the hub the link names is taken in.
///
/// A fresh server whose first boot hasn't happened yet (its status says `first_boot: start`)
/// shows its first-boot pages first ([FirstBootScreen]): connecting it to the internet, then
/// making the family on a phone or restoring one. The link they hand the phone comes back here
/// with `first_boot: family`, and this form shows at once.
class StartFamilyScreen extends StatefulWidget {
  const StartFamilyScreen(
      {super.key, this.initialTimeZone, this.hub, this.setupCode, this.hubDevice, this.web, this.browser, this.firstBoot});

  /// Overrides the device's time zone, for tests and screenshots.
  final String? initialTimeZone;

  /// The fresh hub that served this page, for tests; by default asked of the hub on the web.
  final HubInfo? hub;

  /// The setup code from the hub's setup link.
  final String? setupCode;

  /// The device id of the hub that printed the setup link.
  final String? hubDevice;

  /// The browser, for tests; by default read from the page.
  final WebAppInfo? web;

  /// Runs as a browser served by the hub, for tests; by default only on the web.
  final bool? browser;

  /// The server's first-boot pages, for tests; by default the hub's own when its status says so.
  final FirstBootSource? firstBoot;

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
  bool _inSafari = false;
  String? _error;

  /// Typing the setup code after all: the link named another hub than the one that answered.
  bool _typeCode = false;

  /// "Make it on this device instead", from the first-boot pages.
  bool _hereInstead = false;
  FirstBootSource? _firstBoot;

  /// The link brought the setup code.
  bool get _linked => widget.setupCode != null && !_typeCode;

  /// A fresh hub on the home network, which is this device's to claim with no code.
  bool get _open => _hub?.open == true && !_hub!.paired;

  /// The hub that answered isn't the one the setup link names.
  bool get _wrongHub {
    final hub = _hub;
    return _linked && widget.hubDevice != null && hub != null && hub.device.isNotEmpty && hub.device != widget.hubDevice;
  }

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
    final code = _linked ? widget.setupCode! : _code.text.trim();
    if (hub != null && code.isEmpty && !_open) return;
    if (_wrongHub) return;
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
        Pairing.adoption.value = pairing.adoptServingHub(hub, code, expectDevice: widget.hubDevice);
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
    final web = widget.web ?? WebApp.info;
    final served = _hub;
    if ((_linked || _open) && !_hereInstead && (widget.firstBoot != null || (served?.firstBoot == 'start' && !served!.paired))) {
      final source = _firstBoot ??= widget.firstBoot ?? HubFirstBoot(served!.base, widget.setupCode ?? '');
      return FirstBootScreen(source: source, onMakeHere: () => setState(() => _hereInstead = true));
    }
    if ((widget.browser ?? Capabilities.web) && web.needsHomeScreen && !_inSafari) {
      return DenPage(
        title: 'Start your family',
        children: [
          HomeScreenSteps(
            ipad: web.ipad,
            link: _linked ? DenLink(kind: DenLinkKind.setup, code: widget.setupCode, hubDevice: widget.hubDevice) : null,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => setState(() => _inSafari = true), child: const Text('Use Den in Safari instead')),
          ),
        ],
      );
    }

    return DenPage(
      title: _linked ? 'Start your family' : 'Start a family',
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
        if (_wrongHub)
          ErrorState(
            message: "This page came from another hub than the one that printed the link. Open the link from the hub's own output again.",
            actionLabel: 'Type the setup code instead',
            onAction: () => setState(() => _typeCode = true),
          )
        else if (_adopting && (_linked || _open))
          NoticeLine(icon: PhosphorIconsRegular.hardDrives, message: "${_hub!.name} joins as the family's hub")
        else if (_adopting)
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
