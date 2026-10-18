import 'dart:async';

import 'package:den_capture/den_capture.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../capture/capture_service.dart';
import '../../capture/capture_settings.dart';
import '../../capture/platform_capture.dart';
import '../../design/parts/family_frame.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';

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
            choice(ReaderChoice.device, 'This device', '$_deviceWords. Nothing leaves this device.'),
            choice(ReaderChoice.home, 'A model at home', 'Through Ollama on the hub\'s computer or another one at home'),
            choice(ReaderChoice.claude, 'Claude', 'Anthropic reads what you share and your family\'s first names and lists'),
            if (s.reader == ReaderChoice.home) ...[
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
            if (s.reader == ReaderChoice.claude) ...[
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
            if (s.reader != ReaderChoice.device)
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
          ],
        );
      },
    );
  }
}
