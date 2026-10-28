import 'dart:async';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart' show DenAction, DeviceMode;
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/capture/platform_capture.dart';
import '../../add/add.dart';

/// Advanced → AI and automations → Reading photos and messages: who reads what this device
/// shares (this device, a model at home, Claude with a key kept on this device), and the reader
/// a parent sets up on the family's hub for every device. Whether what Den reads is added at once
/// or shown first is the family's, in Settings → Family.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final _key = TextEditingController();
  final _address = TextEditingController();
  final _model = TextEditingController();
  CaptureService? _service;
  DeviceAbilities? _device;
  bool _showKey = false;
  String? _keyError;

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
    if (d == null) return "Den's own reader";
    return switch (d.modelState) {
      ModelState.available when d.modelName != null => '${d.modelName}, then Den\'s own reader',
      ModelState.downloadable when d.modelName != null => 'Den\'s own reader; ${d.modelName} can download',
      ModelState.downloading when d.modelName != null => 'Den\'s own reader; ${d.modelName} is downloading',
      _ => "Den's own reader",
    };
  }

  Future<void> _saveKey(CaptureSettings settings) async {
    final key = _key.text.trim();
    if (key.isEmpty) return;
    if (!key.startsWith('sk-ant-')) {
      setState(() => _keyError = "That doesn't look like a Claude API key. Keys start with sk-ant-.");
      return;
    }
    await settings.setClaudeKey(key);
    _key.clear();
    if (mounted) {
      setState(() {
        _showKey = false;
        _keyError = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final t = context.text;
    final service = Capture.of(context);
    final hasHub = app.den.devices.any((d) => d.mode == DeviceMode.hub && d.approved && !d.revoked);
    return ListenableBuilder(
      listenable: service.settings,
      builder: (context, _) {
        final s = service.settings;
        final hubReady = service.hub?.status?.ready ?? false;
        return DenPage(
          title: 'Reading photos and messages',
          children: [
            DenSection(
              title: 'On this device',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ChoiceRows<ReaderChoice>(
                    choices: [
                      Choice(
                        ReaderChoice.device,
                        'This device',
                        detail: hubReady ? '$_deviceWords, then the family\'s hub' : '$_deviceWords. Nothing leaves this device.',
                      ),
                      // A browser reaches readers only through the family's hub: the page may talk
                      // to the hub and nothing else.
                      if (!Capabilities.web) ...[
                        const Choice(ReaderChoice.home, 'A model at home', detail: 'Ollama on the hub\'s computer or another one'),
                        const Choice(ReaderChoice.claude, 'Claude', detail: 'Anthropic reads what you share, and the family\'s first names and lists'),
                      ],
                    ],
                    value: Capabilities.web ? ReaderChoice.device : s.reader,
                    onChanged: (v) => s.reader = v,
                  ),
                  if (!Capabilities.web && s.reader != ReaderChoice.device) ...[
                    const RowRule(),
                    SwitchLine(
                      label: 'Try this device first',
                      detail: 'The other reader gets only what this device can\'t read, like photos',
                      value: s.deviceFirst,
                      onChanged: (v) => s.deviceFirst = v,
                    ),
                  ],
                ],
              ),
            ),
            if (!Capabilities.web && s.reader == ReaderChoice.home)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LabeledField(
                    label: 'Address',
                    child: TextField(
                      controller: _address,
                      style: t.body(c.ink),
                      decoration: const InputDecoration(hintText: '192.168.1.20:11434'),
                      onChanged: (v) => s.homeAddress = v,
                    ),
                  ),
                  const SizedBox(height: Sp.l),
                  LabeledField(
                    label: 'Model',
                    child: TextField(controller: _model, style: t.body(c.ink), onChanged: (v) => s.homeModel = v),
                  ),
                ],
              ),
            if (!Capabilities.web && s.reader == ReaderChoice.claude)
              DenSection(
                title: 'Claude',
                carded: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (s.hasClaudeKey && !_showKey)
                      GroupCard(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 56),
                          child: Row(
                            children: [
                              Icon(PhosphorIconsRegular.key, size: 22, color: c.ink),
                              const SizedBox(width: 14),
                              Expanded(child: Text('API key saved on this device', style: t.body(c.ink))),
                              TextButton(onPressed: () => setState(() => _showKey = true), child: const Text('Replace')),
                              TextButton(
                                style: TextButton.styleFrom(foregroundColor: c.destructive),
                                onPressed: () => s.setClaudeKey(null),
                                child: const Text('Remove'),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      LabeledField(
                        label: 'Claude API key',
                        error: _keyError,
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _key,
                                obscureText: true,
                                autocorrect: false,
                                enableSuggestions: false,
                                style: t.body(c.ink),
                                decoration: const InputDecoration(hintText: 'sk-ant-...'),
                                onSubmitted: (_) => _saveKey(s),
                              ),
                            ),
                            const SizedBox(width: Sp.s),
                            FilledButton(onPressed: () => _saveKey(s), child: const Text('Save')),
                          ],
                        ),
                      ),
                    const SizedBox(height: Sp.l),
                    GroupCard(
                      child: ChoiceRows<String>(
                        choices: [for (final m in ClaudeReader.models.entries) Choice(m.key, m.value)],
                        value: ClaudeReader.models.containsKey(s.claudeModel) ? s.claudeModel : ClaudeReader.defaultModel,
                        onChanged: (m) => s.claudeModel = m,
                      ),
                    ),
                  ],
                ),
              ),
            if (_device?.modelState == ModelState.downloadable)
              Align(
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
            if (service.hub != null && hasHub) _HubReaderBlock(hub: service.hub!, onChanged: () => setState(() {})),
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

  /// Tells the page the hub's reader changed, so its other lines can say so.
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
  String? _error;
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
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final status = await widget.hub.client.configure(setup);
      await widget.hub.refresh(force: true);
      if (mounted) setState(() => _show(status));
      widget.onChanged();
    } on ReaderException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final t = context.text;
    final status = _status;
    final parent = app.allows(DenAction.manageFamily) && app.den.thisDevice?.mode != DeviceMode.shared;
    Widget section(Widget child) => DenSection(title: "The family's hub", carded: false, child: child);
    if (_loading) {
      return section(GroupCard(
        child: Padding(padding: const EdgeInsets.symmetric(vertical: Sp.l), child: Text('Asking the hub', style: t.body(c.ink2))),
      ));
    }
    if (status == null) {
      return section(GroupCard(
        child: ErrorState(message: "Can't reach the hub from here. Try again at home.", actionLabel: 'Try again', onAction: _load),
      ));
    }
    final reader = status.reader;
    return section(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NoticeLine(
            icon: PhosphorIconsRegular.hardDrives,
            message: !status.ready
                ? 'Nothing on the hub yet: each device reads on its own.'
                : status.deviceFirst
                    ? '${reader!.name} on the hub. Every device reads on its own first, then asks the hub.'
                    : '${reader!.name} on the hub. Every device asks the hub first.',
          ),
          if (parent) ...[
            const SizedBox(height: Sp.s),
            GroupCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ChoiceRows<HubReaderKind>(
                    choices: const [
                      Choice(HubReaderKind.none, 'Nothing'),
                      Choice(HubReaderKind.home, 'A model at home'),
                      Choice(HubReaderKind.claude, 'Claude'),
                    ],
                    value: _kind,
                    onChanged: (k) => setState(() => _kind = k),
                  ),
                  if (_kind != HubReaderKind.none) ...[
                    const RowRule(),
                    SwitchLine(
                      label: 'Each device tries first',
                      value: _deviceFirst,
                      onChanged: (v) => setState(() => _deviceFirst = v),
                    ),
                  ],
                ],
              ),
            ),
            if (_kind == HubReaderKind.claude) ...[
              const SizedBox(height: Sp.l),
              if (status.keySaved && !_replaceKey)
                Row(
                  children: [
                    Expanded(child: Text('API key saved on the hub', style: t.body(c.ink))),
                    TextButton(onPressed: () => setState(() => _replaceKey = true), child: const Text('Replace')),
                  ],
                )
              else
                LabeledField(
                  label: 'Claude API key for the hub',
                  child: TextField(
                    controller: _key,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: t.body(c.ink),
                    decoration: const InputDecoration(hintText: 'sk-ant-...'),
                  ),
                ),
              const SizedBox(height: Sp.l),
              GroupCard(
                child: ChoiceRows<String>(
                  choices: [for (final m in ClaudeReader.models.entries) Choice(m.key, m.value)],
                  value: _claudeModel,
                  onChanged: (m) => setState(() => _claudeModel = m),
                ),
              ),
            ],
            if (_kind == HubReaderKind.home) ...[
              const SizedBox(height: Sp.l),
              LabeledField(
                label: 'Address the hub reaches it at',
                child: TextField(
                  controller: _address,
                  style: t.body(c.ink),
                  decoration: const InputDecoration(hintText: '127.0.0.1:11434'),
                ),
              ),
              const SizedBox(height: Sp.l),
              LabeledField(label: 'Model', child: TextField(controller: _model, style: t.body(c.ink))),
            ],
            if (_error != null) ...[
              const SizedBox(height: Sp.m),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
                child: Text(_error!, style: t.meta(c.destructive)),
              ),
            ],
            const SizedBox(height: Sp.l),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(onPressed: _saving ? null : _save, child: const Text('Save on the hub')),
            ),
          ],
        ],
      ),
    );
  }
}
