import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/hub_client.dart' show HubException;
import '../../../platform/sync/server_setup.dart';

enum _Step { finding, address, signIn, share }

/// Finding the family's NAS and a shared folder on it, one thing per page: the NASes that
/// answered on the home network (or "Type your NAS's name or address"), its username and
/// password, then the shared folder and the folder in it. The server does the reaching; this
/// only asks. [finish] gets the place chosen and answers a problem to show, or null when done.
/// Used by Settings, Backups ("Back up to a NAS") and the first boot's "Restore from a backup".
class NasPicker extends StatefulWidget {
  const NasPicker({
    super.key,
    required this.find,
    required this.shares,
    required this.finish,
    required this.finishLabel,
    required this.onBack,
    this.askFolder = true,
    this.initial,
  });

  final Future<List<FoundNas>> Function() find;
  final Future<List<String>> Function(NasPlace place) shares;
  final Future<String?> Function(NasPlace place) finish;

  /// The last page's button: "Use this folder", "Find backups".
  final String finishLabel;

  /// Leaves the picker from its first page.
  final VoidCallback onBack;

  /// Whether the last page asks for the folder inside the shared folder too.
  final bool askFolder;

  /// The NAS as it was set up before, to start from.
  final NasPlace? initial;

  @override
  State<NasPicker> createState() => _NasPickerState();
}

class _NasPickerState extends State<NasPicker> {
  _Step _step = _Step.finding;
  List<FoundNas>? _found;
  final _host = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _folder = TextEditingController(text: NasPlace.defaultFolder);
  String? _name;
  List<String> _shares = const [];
  String? _share;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _host.text = initial.host;
      _user.text = initial.user;
      _name = initial.name;
      _folder.text = initial.folder;
      _share = initial.share.isEmpty ? null : initial.share;
    }
    widget.find().then((found) {
      if (!mounted) return;
      setState(() {
        _found = found;
        if (found.isEmpty && _step == _Step.finding) _step = _Step.address;
      });
    }, onError: (Object _) {
      if (mounted && _step == _Step.finding) setState(() => _step = _Step.address);
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _user.dispose();
    _password.dispose();
    _folder.dispose();
    super.dispose();
  }

  NasPlace get _place => NasPlace(
        host: _host.text.trim(),
        user: _user.text.trim(),
        password: _password.text,
        name: _name,
        share: _share ?? '',
        folder: _folder.text.trim().isEmpty ? NasPlace.defaultFolder : _folder.text.trim(),
      );

  void _go(_Step step) => setState(() {
        _step = step;
        _error = null;
      });

  Future<void> _signIn() async {
    if (_user.text.trim().isEmpty) {
      setState(() => _error = 'Add the NAS\'s username.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final shares = await widget.shares(_place);
      if (!mounted) return;
      setState(() {
        _shares = shares;
        if (!shares.contains(_share)) _share = shares.isEmpty ? null : shares.first;
        _busy = false;
        _step = _Step.share;
      });
    } on HubException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _finish() async {
    if (_share == null) {
      setState(() => _error = 'Pick a shared folder.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await widget.finish(_place);
    if (mounted) {
      setState(() {
        _busy = false;
        _error = problem;
      });
    }
  }

  Widget _button(String label, VoidCallback onPressed, {String? busy}) => FilledButton(
        onPressed: _busy ? null : onPressed,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(_busy ? busy ?? label : label),
      );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return switch (_step) {
      _Step.finding => DenPage(
          title: 'Your NAS',
          onBack: widget.onBack,
          children: [
            if (_found == null)
              const NoticeLine(icon: PhosphorIconsBold.magnifyingGlass, message: 'Looking for it on your home network')
            else
              GroupCard(
                child: Column(
                  children: ruled([
                    for (final f in _found!)
                      NavRow(
                        icon: PhosphorIconsRegular.hardDrives,
                        label: f.name,
                        value: f.name == f.host ? null : f.host,
                        onTap: () {
                          _host.text = f.host;
                          _name = f.name;
                          _go(_Step.signIn);
                        },
                      ),
                    NavRow(
                      icon: PhosphorIconsRegular.keyboard,
                      label: 'Type its name or address',
                      onTap: () => _go(_Step.address),
                    ),
                  ], indent: 36),
                ),
              ),
          ],
        ),
      _Step.address => DenPage(
          title: 'Your NAS',
          onBack: _found == null || _found!.isEmpty ? widget.onBack : () => _go(_Step.finding),
          bottom: _button('Next', () {
            if (_host.text.trim().isEmpty) {
              setState(() => _error = 'Type your NAS\'s name or address.');
              return;
            }
            _name = null;
            _go(_Step.signIn);
          }),
          children: [
            Text('Type your NAS\'s name or address.', style: t.body(c.ink)),
            LabeledField(
              label: 'Name or address',
              error: _error,
              child: TextField(
                controller: _host,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                style: t.body(c.ink),
                decoration: const InputDecoration(hintText: 'nas.local or 192.168.1.40'),
              ),
            ),
            Text('It\'s on the NAS\'s own settings page, or on your router\'s list of devices.', style: t.meta(c.ink2)),
          ],
        ),
      _Step.signIn => DenPage(
          title: 'Sign in to the NAS',
          overline: _name ?? _host.text.trim(),
          onBack: () => _go(_found == null || _found!.isEmpty || _name == null ? _Step.address : _Step.finding),
          bottom: _button('Connect', _signIn, busy: 'Connecting'),
          children: [
            Text('The username and password you use for the NAS.', style: t.body(c.ink)),
            LabeledField(
              label: 'Username',
              child: TextField(
                controller: _user,
                autocorrect: false,
                enableSuggestions: false,
                style: t.body(c.ink),
              ),
            ),
            LabeledField(
              label: 'Password',
              child: TextField(
                controller: _password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                style: t.body(c.ink),
                decoration: InputDecoration(hintText: widget.initial?.hasPassword ?? false ? 'Kept from before' : null),
              ),
            ),
            if (_error != null) ErrorState(message: _error!, actionLabel: 'Try again', onAction: _signIn),
          ],
        ),
      _Step.share => DenPage(
          title: 'Pick a shared folder',
          overline: _name ?? _host.text.trim(),
          onBack: () => _go(_Step.signIn),
          bottom: _button(widget.finishLabel, _finish, busy: 'Checking'),
          children: [
            if (_shares.isEmpty)
              Text('The NAS has no shared folders this user can open. Make one on the NAS, then try again.', style: t.body(c.ink))
            else
              GroupCard(
                child: ChoiceRows<String>(
                  choices: [for (final s in _shares) Choice(s, s)],
                  value: _share ?? '',
                  onChanged: (s) => setState(() => _share = s),
                ),
              ),
            if (widget.askFolder)
              LabeledField(
                label: 'Folder for Den\'s backups',
                child: TextField(controller: _folder, autocorrect: false, style: t.body(c.ink)),
              ),
            if (_error != null) ErrorState(message: _error!, actionLabel: 'Try again', onAction: _finish),
          ],
        ),
    };
  }
}
