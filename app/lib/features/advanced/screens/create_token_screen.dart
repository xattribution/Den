import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../widgets/scope_picker.dart';
import '../../../design/forms/forms.dart';
import '../state/connection_actions.dart';

/// Creating an API token for an AI client or an automation: a label, what it may do and whose
/// permissions it uses. The token is shown once, with Copy.
class CreateTokenScreen extends StatefulWidget {
  const CreateTokenScreen({super.key, this.token, this.label});

  /// Shows the one-time token page directly, for tests.
  final String? token;
  final String? label;

  @override
  State<CreateTokenScreen> createState() => _CreateTokenScreenState();
}

class _CreateTokenScreenState extends State<CreateTokenScreen> {
  final _label = TextEditingController();
  Set<Scope> _scopes = {Scope.read};
  String? _member;
  late String? _token = widget.token;
  bool _copied = false;
  bool _tried = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.label != null) _label.text = widget.label!;
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _tried = true);
    final label = _label.text.trim();
    if (label.isEmpty || _scopes.isEmpty) return;
    setState(() => _busy = true);
    final connections = context.connectionActions;
    String? token;
    await attempt(context, () async => token = await connections.addToken(label: label, scopes: _scopes, member: _member));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _token = token;
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _token!));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final token = _token;
    if (token != null) {
      final label = _label.text.trim();
      return FormFrame(
        title: 'Token for $label',
        back: false,
        bottom: SizedBox(
          width: double.infinity,
          child: OutlinedButton(onPressed: () => context.pop(), child: const Text('Done')),
        ),
        children: [
          FormBlock(
            child: AttentionLine(message: "Den won't show this token again. Copy it now and keep it somewhere safe."),
          ),
          FormBlock(
            top: Sp.m,
            child: Container(
              padding: const EdgeInsets.all(Sp.m),
              decoration: BoxDecoration(color: c.well, borderRadius: BorderRadius.circular(Radii.control)),
              child: SelectableText(token, style: context.type.title(c.ink).copyWith(letterSpacing: 0.5)),
            ),
          ),
          FormBlock(
            top: Sp.m,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _copy,
                icon: Icon(_copied ? PhosphorIconsBold.check : PhosphorIconsRegular.copy, size: 18),
                label: Text(_copied ? 'Copied' : 'Copy token'),
              ),
            ),
          ),
        ],
      );
    }

    return FormFrame(
      title: 'Create token',
      bottom: SizedBox(
        width: double.infinity,
        child: FilledButton(onPressed: _busy || _scopes.isEmpty ? null : _create, child: const Text('Create token')),
      ),
      children: [
        FormBlock(
          child: TextField(
            controller: _label,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Label',
              hintText: 'Home Assistant',
              suffixIcon: const InfoTip('History shows changes made with this token under this name.'),
              suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              errorText: _tried && _label.text.trim().isEmpty ? 'Name the token after what will use it.' : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        ScopePicker(value: _scopes, onChanged: (s) => setState(() => _scopes = s)),
        ActsAsPicker(value: _member, onChanged: (m) => setState(() => _member = m)),
      ],
    );
  }
}
