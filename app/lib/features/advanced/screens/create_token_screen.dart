import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../state/connection_actions.dart';
import '../widgets/scope_picker.dart';

/// Making a token for an automation or a Shortcut that can't sign in: a name, what it may do
/// and whose permissions it uses. The token is shown once, with Copy.
class CreateTokenScreen extends StatefulWidget {
  const CreateTokenScreen({super.key, this.token, this.label});

  /// Shows the one-time token page directly, for tests.
  final String? token;
  final String? label;

  @override
  State<CreateTokenScreen> createState() => _CreateTokenScreenState();
}

class _CreateTokenScreenState extends State<CreateTokenScreen> {
  late final _label = TextEditingController(text: widget.label);
  Set<Scope> _scopes = {Scope.read};
  late String? _member = DenScope.read(context).me?.id;
  late String? _token = widget.token;
  bool _copied = false;
  bool _tried = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final label = widget.label?.toLowerCase() ?? '';
    // What each usual one needs, so the switches start right.
    if (label.contains('home assistant')) _scopes = {Scope.read, Scope.calendar, Scope.chores, Scope.lists};
    if (label.contains('siri')) _scopes = {Scope.read, Scope.calendar, Scope.chores, Scope.lists};
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _tried = true);
    final label = _label.text.trim();
    final member = _member;
    if (label.isEmpty || _scopes.isEmpty || member == null) return;
    setState(() => _busy = true);
    final connections = context.connectionActions;
    String? token;
    await attempt(context, () async => token = await connections.addToken(label: label, scopes: _scopes, member: member));
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
    final t = context.text;
    final token = _token;
    if (token != null) {
      return DenPage(
        title: 'Token for ${_label.text.trim()}',
        back: false,
        bottom: FilledButton(
          onPressed: () => context.pop(),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: const Text('Done'),
        ),
        children: [
          const NoticeLine(
            icon: PhosphorIconsRegular.key,
            message: "Den won't show this token again. Copy it now and keep it somewhere safe.",
          ),
          GroupCard(
            padding: const EdgeInsets.all(Sp.l),
            child: SelectableText(token, style: t.rowTitle(c.ink).copyWith(letterSpacing: 0.5)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _copy,
              icon: Icon(_copied ? PhosphorIconsBold.check : PhosphorIconsRegular.copy, size: 18),
              label: Text(_copied ? 'Copied' : 'Copy token'),
            ),
          ),
        ],
      );
    }

    return DenPage(
      title: 'Make a token',
      bottom: FilledButton(
        onPressed: _busy || _scopes.isEmpty ? null : _create,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: const Text('Make the token'),
      ),
      children: [
        LabeledField(
          label: 'What will use it',
          error: _tried && _label.text.trim().isEmpty ? 'Name it after what will use it, like Home Assistant.' : null,
          child: TextField(
            controller: _label,
            textCapitalization: TextCapitalization.sentences,
            style: t.body(c.ink),
            decoration: const InputDecoration(hintText: 'Home Assistant'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        ScopePicker(value: _scopes, onChanged: (s) => setState(() => _scopes = s)),
        ActsAsPicker(value: _member ?? '', onChanged: (m) => setState(() => _member = m)),
      ],
    );
  }
}
