import 'dart:async';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart' show DenAction, DeviceMode;
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../add/state/capture_service.dart';
import '../../add/state/capture_settings.dart';
import '../../../platform/capture/platform_capture.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../../../platform/capabilities.dart';
import '../../../design/forms/forms.dart';

/// Settings, AI and automations: who reads what this device shares, and whether what Den finds
/// is added right away or shown first. The reader and its key belong to this device; the
/// right-away choice is the family's.
class CaptureSection extends StatefulWidget {
  const CaptureSection({super.key});

  @override
  State<CaptureSection> createState() => _CaptureSectionState();
}

class _CaptureSectionState extends State<CaptureSection> {
  final _key = TextEditingController();
  final _address = TextEditingController();
  final _model = TextEditingController();
  CaptureService? _service;
  DeviceAbilities? _device;
  bool _showKey = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = Capture.of(context);
    if (identical(service, _service)) return;
    _service = service;
    _address.text = service.settings.homeAddress;
    _model.text = service.settings.homeModel;
    service.abilities().then((device) {
      if (mounted) setState(() => _device = device);
    });
  }

  @override
  void dispose() {
    _key.dispose();
    _address.dispose();
    _model.dispose();
    super.dispose();
  }

  String get _deviceWords {
    final d = _device;
    if (d == null) return 'Den\'s own reader';
    return switch (d.modelState) {
      ModelState.available when d.modelName != null => '${d.modelName}, then Den\'s own reader',
      ModelState.downloadable when d.modelName != null => 'Den\'s own reader; ${d.modelName} can download',
      ModelState.downloading when d.modelName != null => 'Den\'s own reader; ${d.modelName} is downloading',
      _ => 'Den\'s own reader',
    };
  }

  Future<void> _saveKey(CaptureSettings settings) async {
    final key = _key.text.trim();
    if (key.isEmpty) return;
    if (!key.startsWith('sk-ant-')) {
      showNote(context, 'That doesn\'t look like a Claude API key. Keys start with sk-ant-.');
      return;
    }
    await settings.setClaudeKey(key);
    _key.clear();
    if (mounted) setState(() => _showKey = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final service = Capture.of(context);
    final family = app.den.family;
    return ListenableBuilder(
      listenable: service.settings,
      builder: (context, _) {
        final s = service.settings;
        Widget choice(ReaderChoice value, String title, String subtitle) => ListTile(
              leading: Icon(
                s.reader == value ? PhosphorIconsFill.radioButton : PhosphorIconsRegular.circle,
                color: s.reader == value ? c.ink : c.ink2,
              ),
              title: Text(title),
              subtitle: Text(subtitle),
              selected: s.reader == value,
              onTap: () => s.reader = value,
            );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const InfoHeader(
              'Reading what you share',
              info: 'Photos, emails, links and things you type or say become events, chores, list items and reminders. '
                  'Den reads them on this device unless you choose a reader here.',
            ),
            if (family != null)
              FormBlock(
                top: 0,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Segmented<bool>(
                    options: const {false: 'Add right away', true: 'Show me first'},
                    value: family.captureNeedsReview,
                    onChanged: (review) => attempt(context, () => app.den.updateFamily({'capture': review ? 'review' : 'direct'})),
                  ),
                ),
              ),
            const SizedBox(height: Sp.s),
            choice(
              ReaderChoice.device,
              'This device',
              service.hub?.status?.ready ?? false
                  ? '$_deviceWords, then the family\'s hub'
                  : '$_deviceWords. Nothing leaves this device.',
            ),
            // A browser reaches readers only through the family's hub (below): the page may
            // talk to the hub and nothing else.
            if (!Capabilities.web) ...[
              choice(ReaderChoice.home, 'A model at home', 'Through Ollama on the hub\'s computer or another one at home'),
              choice(ReaderChoice.claude, 'Claude', 'Anthropic reads what you share and your family\'s first names and lists'),
            ],
            if (!Capabilities.web && s.reader == ReaderChoice.home) ...[
              FormBlock(
                child: TextField(
                  controller: _address,
                  decoration: const InputDecoration(labelText: 'Address', hintText: '192.168.1.20:11434'),
                  onChanged: (v) => s.homeAddress = v,
                ),
              ),
              FormBlock(
                child: TextField(
                  controller: _model,
                  decoration: const InputDecoration(labelText: 'Model'),
                  onChanged: (v) => s.homeModel = v,
                ),
              ),
            ],
            if (!Capabilities.web && s.reader == ReaderChoice.claude) ...[
              if (s.hasClaudeKey && !_showKey)
                ListTile(
                  leading: Icon(PhosphorIconsRegular.key, color: c.ink2),
                  title: const Text('API key saved on this device'),
                  trailing: Wrap(
                    children: [
                      TextButton(onPressed: () => setState(() => _showKey = true), child: const Text('Replace')),
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: c.bad),
                        onPressed: () => s.setClaudeKey(null),
                        child: const Text('Remove'),
                      ),
                    ],
                  ),
                )
              else
                FormBlock(
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _key,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(labelText: 'Claude API key', hintText: 'sk-ant-...'),
                          onSubmitted: (_) => _saveKey(s),
                        ),
                      ),
                      const SizedBox(width: Sp.s),
                      FilledButton(onPressed: () => _saveKey(s), child: const Text('Save key')),
                    ],
                  ),
                ),
              FormBlock(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Segmented<String>(
                    options: {for (final m in ClaudeReader.models.entries) m.key: m.value.replaceFirst('Claude ', '')},
                    value: ClaudeReader.models.containsKey(s.claudeModel) ? s.claudeModel : ClaudeReader.defaultModel,
                    onChanged: (m) => s.claudeModel = m,
                  ),
                ),
              ),
            ],
            if (!Capabilities.web && s.reader != ReaderChoice.device)
              SwitchListTile(
                title: const Row(
                  children: [
                    Flexible(child: Text('Try this device first')),
                    InfoTip('Den reads on this device and asks the other reader only for what it can\'t read here, such as photos.'),
                  ],
                ),
                value: s.deviceFirst,
                onChanged: (v) => s.deviceFirst = v,
              ),
            if (_device?.modelState == ModelState.downloadable)
              FormBlock(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: () async {
                      unawaited(service.platform.prepareModel());
                      service.refreshAbilities();
                      final d = await service.abilities();
                      if (mounted) setState(() => _device = d);
                    },
                    child: Text('Download ${_device!.modelName}'),
                  ),
                ),
              ),
            if (service.hub != null && app.den.devices.any((d) => d.mode == DeviceMode.hub && d.approved && !d.revoked))
              _HubReaderBlock(hub: service.hub!, onChanged: () => setState(() {})),
          ],
        );
      },
    );
  }
}

/// The reader a parent sets up on the family's hub, for every device. The key goes to the hub
/// and stays there; this device never keeps it.
class _HubReaderBlock extends StatefulWidget {
  const _HubReaderBlock({required this.hub, required this.onChanged});
  final HubReader hub;

  /// Tells the section the hub's reader changed, so its other lines can say so.
  final VoidCallback onChanged;

  @override
  State<_HubReaderBlock> createState() => _HubReaderBlockState();
}

class _HubReaderBlockState extends State<_HubReaderBlock> {
  final _key = TextEditingController();
  final _address = TextEditingController();
  final _model = TextEditingController();
  HubReaderStatus? _status;
  bool _loading = true;
  bool _saving = false;
  bool _replaceKey = false;
  HubReaderKind _kind = HubReaderKind.none;
  String _claudeModel = ClaudeReader.defaultModel;
  bool _deviceFirst = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _key.dispose();
    _address.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final status = await widget.hub.refresh(force: true);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _show(status);
    });
    widget.onChanged();
  }

  void _show(HubReaderStatus? status) {
    _status = status;
    if (status == null) return;
    _kind = status.kind;
    _deviceFirst = status.deviceFirst;
    if (status.kind == HubReaderKind.claude && ClaudeReader.models.containsKey(status.model)) _claudeModel = status.model!;
    if (status.kind == HubReaderKind.home) {
      _address.text = status.address ?? '';
      _model.text = status.model ?? HomeModelReader.defaultModel;
    }
    _replaceKey = false;
    _key.clear();
  }

  Future<void> _save() async {
    final key = _key.text.trim();
    final setup = switch (_kind) {
      HubReaderKind.none => const HubReaderSetup(kind: HubReaderKind.none),
      HubReaderKind.claude => HubReaderSetup(
          kind: HubReaderKind.claude,
          key: key.isEmpty ? null : key,
          model: _claudeModel,
          deviceFirst: _deviceFirst,
        ),
      HubReaderKind.home => HubReaderSetup(
          kind: HubReaderKind.home,
          address: _address.text.trim(),
          model: _model.text.trim().isEmpty ? null : _model.text.trim(),
          deviceFirst: _deviceFirst,
        ),
    };
    setState(() => _saving = true);
    try {
      final status = await widget.hub.client.configure(setup);
      await widget.hub.refresh(force: true);
      if (mounted) setState(() => _show(status));
      widget.onChanged();
    } on ReaderException catch (e) {
      if (mounted) showNote(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final status = _status;
    final parent = app.allows(DenAction.manageFamily) && app.den.thisDevice?.mode != DeviceMode.shared;
    final header = const InfoHeader(
      'The family\'s hub',
      info: 'Set up once for every device in the family, including kids\' tablets that can add things. '
          'The hub keeps the key; devices never see it.',
    );
    if (_loading) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        ListTile(leading: Icon(PhosphorIconsRegular.hardDrives, color: c.ink2), title: const Text('Asking the hub')),
      ]);
    }
    if (status == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        EmptyLine(message: 'Can\'t reach the hub from here. Try again at home.', actionLabel: 'Try again', onAction: _load),
      ]);
    }
    final reader = status.reader;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        ListTile(
          leading: Icon(PhosphorIconsRegular.hardDrives, color: c.ink2),
          title: Text(status.ready ? '${reader!.name} on the hub' : 'Nothing on the hub yet'),
          subtitle: Text(
            !status.ready
                ? 'Each device reads on its own'
                : status.deviceFirst
                    ? 'Every device reads on its own first, then asks the hub'
                    : 'Every device asks the hub first',
          ),
        ),
        if (parent) ...[
          FormBlock(
            top: Sp.s,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Segmented<HubReaderKind>(
                options: const {
                  HubReaderKind.none: 'Nothing',
                  HubReaderKind.home: 'A model at home',
                  HubReaderKind.claude: 'Claude',
                },
                value: _kind,
                onChanged: (k) => setState(() => _kind = k),
              ),
            ),
          ),
          if (_kind == HubReaderKind.claude) ...[
            if (status.keySaved && !_replaceKey)
              ListTile(
                leading: Icon(PhosphorIconsRegular.key, color: c.ink2),
                title: const Text('API key saved on the hub'),
                trailing: TextButton(onPressed: () => setState(() => _replaceKey = true), child: const Text('Replace')),
              )
            else
              FormBlock(
                child: TextField(
                  controller: _key,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Claude API key for the hub', hintText: 'sk-ant-...'),
                ),
              ),
            FormBlock(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Segmented<String>(
                  options: {for (final m in ClaudeReader.models.entries) m.key: m.value.replaceFirst('Claude ', '')},
                  value: _claudeModel,
                  onChanged: (m) => setState(() => _claudeModel = m),
                ),
              ),
            ),
          ],
          if (_kind == HubReaderKind.home) ...[
            FormBlock(
              child: TextField(
                controller: _address,
                decoration: const InputDecoration(labelText: 'Address the hub reaches it at', hintText: '127.0.0.1:11434'),
              ),
            ),
            FormBlock(child: TextField(controller: _model, decoration: const InputDecoration(labelText: 'Model'))),
          ],
          if (_kind != HubReaderKind.none)
            SwitchListTile(
              title: const Text('Each device tries first'),
              value: _deviceFirst,
              onChanged: (v) => setState(() => _deviceFirst = v),
            ),
          FormBlock(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(onPressed: _saving ? null : _save, child: const Text('Save on the hub')),
            ),
          ),
        ],
      ],
    );
  }
}
