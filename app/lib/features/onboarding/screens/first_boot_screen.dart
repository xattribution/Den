import 'dart:async';

import 'package:den_net/den_net.dart' show RecoveryWords;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/hub_client.dart' show HubException;
import '../../../platform/sync/server_setup.dart';
import '../../settings/widgets/nas_picker.dart';

/// Where to read how to make a Cloudflare tunnel and get its token.
final Uri tunnelHowTo = Uri.parse('https://github.com/xattribution/den-install#cloudflare');

enum FirstBootStep {
  loading,
  internet,
  connecting,
  address,
  connected,
  choose,
  family,
  done,
  restoreFrom,
  nas,
  pick,
  words,
  restoring,
  restored,
}

/// A fresh server's first boot, opened from the setup link its installer printed (docs/hub-api.md,
/// "First boot"), one thing per page in big plain words, at phone and laptop sizes:
///
/// 1. **Connect Den to the internet**: paste the Cloudflare tunnel token, watch it connect, and
///    see the family's address (from the tunnel itself; asked for only when it doesn't say).
///    "Skip — only at home for now" leaves it on the home network.
/// 2. **Make your family** (a QR code of the setup link, so the first parent's phone makes it,
///    as the setup link always did) or **Restore from a backup** (a file from this device, the
///    server's own disk or the NAS; the newest backup; a parent's recovery words).
///
/// Everything goes to the server with the setup code ([FirstBootSource]); the token is never
/// shown again. [onMakeHere] makes the family on this device instead (the start-family form).
class FirstBootScreen extends StatefulWidget {
  const FirstBootScreen({super.key, required this.source, required this.onMakeHere, this.open, this.pickFile, this.initial, this.poll});

  final FirstBootSource source;

  /// Makes the family on this device: the page the setup link opens on a phone.
  final VoidCallback onMakeHere;

  /// Opens a link (tests catch it); by default in the browser.
  final Future<bool> Function(Uri url)? open;

  /// Picks a backup file (tests give one); by default the system's file picker.
  final Future<({String name, List<int> bytes})?> Function()? pickFile;

  /// Starts on this step, for screenshots.
  final FirstBootStep? initial;

  /// How often it looks again while the tunnel connects and the phone makes the family.
  final Duration? poll;

  @override
  State<FirstBootScreen> createState() => FirstBootScreenState();
}

class FirstBootScreenState extends State<FirstBootScreen> {
  FirstBootStep _step = FirstBootStep.loading;
  FirstBootState? _state;
  final _token = TextEditingController();
  final _address = TextEditingController();
  final _words = TextEditingController();
  String? _error;
  bool _busy = false;
  Timer? _timer;
  int _waited = 0;

  // Restoring.
  String _from = 'upload';
  NasPlace? _place;
  BackupFileInfo? _uploaded;
  String? _uploadedName;
  List<BackupItem> _backups = const [];
  String? _picked;
  List<BackupItem> _onServer = const [];
  String? _restoredName;

  FirstBootSource get _source => widget.source;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _token.dispose();
    _address.dispose();
    _words.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final state = await _source.state();
      final disk = await _source.backups().catchError((Object _) => const <BackupItem>[]);
      if (!mounted) return;
      setState(() {
        _state = state;
        _onServer = disk;
        _step = widget.initial ??
            (state.internet.connected && state.address != null
                ? FirstBootStep.choose
                : state.internet.token
                    ? FirstBootStep.connecting
                    : FirstBootStep.internet);
      });
      if (_step == FirstBootStep.connecting) _watchTunnel();
      if (_step == FirstBootStep.family) _watchFamily();
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _go(FirstBootStep step) => setState(() {
        _step = step;
        _error = null;
        _busy = false;
      });

  Future<bool> _open(Uri url) =>
      (widget.open ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank'))(url);

  Duration get _every => widget.poll ?? const Duration(seconds: 2);

  // ---------------------------------------------------------------- the internet

  Future<void> _connect() async {
    if (_token.text.trim().isEmpty) {
      setState(() => _error = 'Paste the token first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = await _source.saveToken(_token.text);
      _token.clear();
      if (!mounted) return;
      setState(() => _state = state);
      _go(FirstBootStep.connecting);
      _watchTunnel();
    } on HubException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  void _watchTunnel() {
    _timer?.cancel();
    _waited = 0;
    _timer = Timer.periodic(_every, (_) async {
      _waited++;
      try {
        final state = await _source.state();
        if (!mounted || _step != FirstBootStep.connecting) return;
        setState(() => _state = state);
        if (state.internet.connected && state.address != null) {
          _timer?.cancel();
          _go(FirstBootStep.connected);
        } else if (state.internet.connected && _waited >= 4) {
          // Connected, and the tunnel doesn't say its address: ask.
          _timer?.cancel();
          _go(FirstBootStep.address);
        }
      } on HubException {
        // Looked again next time.
      }
    });
  }

  Future<void> _saveAddress() async {
    if (_address.text.trim().isEmpty) {
      setState(() => _error = 'Type your family\'s address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = await _source.saveAddress(_address.text);
      if (!mounted) return;
      setState(() => _state = state);
      _go(FirstBootStep.connected);
    } on HubException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  // ---------------------------------------------------------------- the family

  Future<void> _makeFamily() async {
    setState(() => _busy = true);
    try {
      await _source.chooseFamily();
      final state = await _source.state();
      if (!mounted) return;
      setState(() => _state = state);
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (!mounted) return;
    _go(FirstBootStep.family);
    _watchFamily();
  }

  void _watchFamily() {
    _timer?.cancel();
    _timer = Timer.periodic(_every * 2, (_) async {
      if (await _source.paired() && mounted) {
        _timer?.cancel();
        _go(FirstBootStep.done);
      }
    });
  }

  // ---------------------------------------------------------------- restoring

  Future<void> _pickFile() async {
    setState(() => _error = null);
    try {
      final picked = await (widget.pickFile ?? _systemPick)();
      if (picked == null || !mounted) return;
      setState(() => _busy = true);
      final info = await _source.upload(picked.bytes);
      if (!mounted) return;
      setState(() {
        _from = 'upload';
        _uploaded = info;
        _uploadedName = picked.name;
        _busy = false;
        _step = FirstBootStep.words;
      });
    } on HubException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } on Object {
      if (mounted) setState(() => _error = 'Couldn\'t open that file. Pick the one whose name ends in .denbackup.');
    }
  }

  static Future<({String name, List<int> bytes})?> _systemPick() async {
    final file = await openFile();
    if (file == null) return null;
    return (name: file.name, bytes: await file.readAsBytes());
  }

  Future<String?> _nasChosen(NasPlace place) async {
    try {
      final found = await _source.backups(place: place);
      if (found.isEmpty) return 'There are no Den backups in ${place.share}/${place.folder}. Pick the folder they\'re in.';
      if (!mounted) return null;
      setState(() {
        _from = 'nas';
        _place = place;
        _backups = found;
        _picked = found.first.name;
        _step = FirstBootStep.pick;
        _error = null;
      });
      return null;
    } on HubException catch (e) {
      return e.message;
    }
  }

  void _fromServer() => setState(() {
        _from = 'disk';
        _place = null;
        _backups = _onServer;
        _picked = _onServer.first.name;
        _step = FirstBootStep.pick;
        _error = null;
      });

  Future<void> _restore() async {
    final needsPassphrase = _uploaded?.needsPassphrase ?? false;
    final text = _words.text.trim();
    if (!needsPassphrase && RecoveryWords.parse(text) == null) {
      setState(() => _error = RecoveryWords.countIn(text) < 12
          ? 'Type all 12 words. ${RecoveryWords.countIn(text)} so far.'
          : 'Those aren\'t quite the 12 words. Check each one.');
      return;
    }
    if (needsPassphrase && text.isEmpty && !(_state?.passphraseKnown ?? false)) {
      setState(() => _error = 'Type the backup\'s passphrase.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _step = FirstBootStep.restoring;
    });
    try {
      final name = await _source.restore(
        from: _from,
        name: _from == 'upload' ? null : _picked,
        place: _place,
        words: needsPassphrase ? null : text,
        passphrase: needsPassphrase && text.isNotEmpty ? text : null,
      );
      if (!mounted) return;
      _words.clear();
      setState(() => _restoredName = name);
      _go(FirstBootStep.restored);
    } on HubException catch (e) {
      if (mounted) {
        setState(() {
          _step = FirstBootStep.words;
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  // ---------------------------------------------------------------- pages

  Widget _primary(String label, VoidCallback onPressed, {String? busy}) => FilledButton(
        onPressed: _busy ? null : onPressed,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(_busy ? busy ?? label : label),
      );

  Widget _say(String text) => Text(tidy(text), style: context.text.body(context.colors.ink));

  Widget _quiet(String label, VoidCallback onPressed) =>
      Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: onPressed, child: Text(label)));

  static String _when(int at) => DateFormat("MMM d, h:mm a").format(DateTime.fromMillisecondsSinceEpoch(at));

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final state = _state;
    switch (_step) {
      case FirstBootStep.loading:
        return DenPage(
          title: 'Set up Den',
          back: false,
          children: [
            if (_error == null)
              const NoticeLine(icon: PhosphorIconsBold.hardDrives, message: 'Talking to the server')
            else
              ErrorState(message: _error!, actionLabel: 'Try again', onAction: () {
                setState(() => _error = null);
                _load();
              }),
          ],
        );

      case FirstBootStep.internet:
        return DenPage(
          title: 'Connect Den to the internet',
          back: false,
          bottom: _primary('Connect', _connect, busy: 'Saving'),
          children: [
            _say('Paste your Cloudflare tunnel token.'),
            LabeledField(
              label: 'Tunnel token',
              error: _error,
              child: TextField(
                controller: _token,
                minLines: 3,
                maxLines: 5,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                style: t.body(c.ink),
                decoration: const InputDecoration(hintText: 'eyJhIjoi…'),
              ),
            ),
            _quiet('How do I get one?', () => _open(tunnelHowTo)),
            _quiet('Skip — only at home for now', () => _go(FirstBootStep.choose)),
          ],
        );

      case FirstBootStep.connecting:
        final problem = state?.internet.problem;
        return DenPage(
          title: 'Connecting',
          onBack: () => _go(FirstBootStep.internet),
          children: [
            if (problem != null)
              ErrorState(message: problem, actionLabel: 'Paste it again', onAction: () => _go(FirstBootStep.internet))
            else
              const NoticeLine(icon: PhosphorIconsBold.globeHemisphereWest, message: 'Connecting to Cloudflare. This takes a few seconds.'),
          ],
        );

      case FirstBootStep.address:
        return DenPage(
          title: 'Your family\'s address',
          onBack: () => _go(FirstBootStep.internet),
          bottom: _primary('Save', _saveAddress, busy: 'Saving'),
          children: [
            const NoticeLine(icon: PhosphorIconsBold.check, message: 'Connected to Cloudflare'),
            _say('What address did you give it in Cloudflare?'),
            LabeledField(
              label: 'Address',
              error: _error,
              child: TextField(
                controller: _address,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                style: t.body(c.ink),
                decoration: const InputDecoration(hintText: 'den.yourfamily.com'),
              ),
            ),
          ],
        );

      case FirstBootStep.connected:
        return DenPage(
          title: 'Connected',
          back: false,
          bottom: _primary('Next', () => _go(FirstBootStep.choose)),
          children: [
            _say('Your family\'s address:'),
            SelectableText(state?.addressText ?? '', style: t.sheetTitle(c.ink)),
            Text(tidy('Everyone in the family opens Den here, from anywhere.'), style: t.meta(c.ink2)),
          ],
        );

      case FirstBootStep.choose:
        return DenPage(
          title: 'Your family',
          back: false,
          children: [
            GroupCard(
              child: Column(
                children: ruled([
                  NavRow(
                    icon: PhosphorIconsRegular.usersThree,
                    label: 'Make your family',
                    detail: 'Start fresh, on your phone',
                    onTap: _busy ? null : _makeFamily,
                  ),
                  NavRow(
                    icon: PhosphorIconsRegular.clockCounterClockwise,
                    label: 'Restore from a backup',
                    detail: 'Bring your family back on this server',
                    onTap: () => _go(FirstBootStep.restoreFrom),
                  ),
                ], indent: 36),
              ),
            ),
            if (_error != null) ErrorState(message: _error!, actionLabel: 'Try again', onAction: _makeFamily),
          ],
        );

      case FirstBootStep.family:
        final link = state?.setupLink;
        final compact = DenLayout.forWidth(MediaQuery.sizeOf(context).width).isCompact;
        return DenPage(
          title: 'Finish on your phone',
          onBack: () => _go(FirstBootStep.choose),
          children: [
            _say('Open your phone\'s camera and point it here.'),
            if (link != null)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(Sp.m),
                  decoration: BoxDecoration(color: DenColors.day.card, borderRadius: BorderRadius.circular(Radii.tile)),
                  child: QrImageView(
                    data: link,
                    size: compact ? 220 : 280,
                    padding: EdgeInsets.zero,
                    backgroundColor: DenColors.day.card,
                    eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: DenColors.day.ink),
                    dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: DenColors.day.ink),
                    semanticsLabel: 'The link that makes your family',
                  ),
                ),
              ),
            if (state?.addressText != null) Text(tidy('Or open ${state!.addressText} on your phone.'), style: t.meta(c.ink2)),
            const NoticeLine(icon: PhosphorIconsBold.deviceMobile, message: 'This page moves on once your phone has made the family.'),
            _quiet('Make it on this device instead', () {
              _timer?.cancel();
              final address = state?.address;
              if (link != null && address != null && Uri.base.host != Uri.parse(address).host) {
                _open(Uri.parse(link));
              } else {
                widget.onMakeHere();
              }
            }),
          ],
        );

      case FirstBootStep.done:
        return DenPage(
          title: 'You\'re all set',
          back: false,
          children: [
            _say('Your family is on Den. You can close this page.'),
          ],
        );

      case FirstBootStep.restoreFrom:
        return DenPage(
          title: 'Where is the backup?',
          onBack: () => _go(FirstBootStep.choose),
          children: [
            GroupCard(
              child: Column(
                children: ruled([
                  NavRow(
                    icon: PhosphorIconsRegular.file,
                    label: 'A file on this device',
                    detail: 'Its name ends in .denbackup',
                    onTap: _busy ? null : _pickFile,
                  ),
                  NavRow(icon: PhosphorIconsRegular.hardDrives, label: 'On your NAS', onTap: () => _go(FirstBootStep.nas)),
                  if (_onServer.isNotEmpty)
                    NavRow(
                      icon: PhosphorIconsRegular.desktopTower,
                      label: 'On this server',
                      value: _when(_onServer.first.at),
                      onTap: _fromServer,
                    ),
                ], indent: 36),
              ),
            ),
            if (_busy) const NoticeLine(icon: PhosphorIconsBold.uploadSimple, message: 'Sending the backup to the server'),
            if (_error != null) ErrorState(message: _error!, actionLabel: 'Pick another file', onAction: _pickFile),
          ],
        );

      case FirstBootStep.nas:
        return NasPicker(
          find: _source.findNas,
          shares: _source.shares,
          finish: _nasChosen,
          finishLabel: 'Find backups',
          onBack: () => _go(FirstBootStep.restoreFrom),
        );

      case FirstBootStep.pick:
        return DenPage(
          title: 'Pick a backup',
          onBack: () => _go(_from == 'nas' ? FirstBootStep.nas : FirstBootStep.restoreFrom),
          bottom: _primary('Next', () => _go(FirstBootStep.words)),
          children: [
            _say('The newest is picked.'),
            GroupCard(
              child: ChoiceRows<String>(
                choices: [
                  for (final b in _backups.take(14)) Choice(b.name, _when(b.at), detail: b.size > 0 ? sizeWords(b.size) : null),
                ],
                value: _picked ?? '',
                onChanged: (n) => setState(() => _picked = n),
              ),
            ),
          ],
        );

      case FirstBootStep.words:
        final needsPassphrase = _uploaded?.needsPassphrase ?? false;
        final names = _uploaded?.names ?? const [];
        return DenPage(
          title: needsPassphrase ? 'The backup\'s passphrase' : 'Your recovery words',
          onBack: () => _go(_from == 'upload' ? FirstBootStep.restoreFrom : FirstBootStep.pick),
          bottom: _primary('Restore', _restore),
          children: [
            if (_uploadedName != null && _from == 'upload')
              NoticeLine(
                icon: PhosphorIconsBold.file,
                message: [
                  _uploaded?.familyName ?? _uploadedName!,
                  if (_uploaded?.madeAt != null) _when(_uploaded!.madeAt!),
                ].join(', '),
              ),
            _say(needsPassphrase
                ? (_state?.passphraseKnown ?? false)
                    ? 'This backup was made by an older Den. The server knows its passphrase: tap Restore.'
                    : 'This backup was made by an older Den. Type the passphrase it was made with.'
                : names.isEmpty
                    ? 'Type the 12 recovery words a parent saved.'
                    : 'Type the 12 recovery words ${names.join(' or ')} saved.'),
            LabeledField(
              label: needsPassphrase ? 'Passphrase' : 'Recovery words',
              error: _error,
              child: TextField(
                controller: _words,
                minLines: needsPassphrase ? 1 : 3,
                maxLines: needsPassphrase ? 1 : 5,
                obscureText: needsPassphrase,
                autocorrect: false,
                enableSuggestions: false,
                style: t.body(c.ink),
                decoration: InputDecoration(hintText: needsPassphrase ? null : 'maple river candle …'),
              ),
            ),
          ],
        );

      case FirstBootStep.restoring:
        return DenPage(
          title: 'Restoring',
          back: false,
          children: [
            const NoticeLine(icon: PhosphorIconsBold.clockCounterClockwise, message: 'Bringing your family back. This takes a minute.'),
          ],
        );

      case FirstBootStep.restored:
        return DenPage(
          title: 'Your family is back',
          back: false,
          children: [
            _say('${_restoredName ?? 'Your family'} is on this server now. Open Den on your phones: they find it by '
                'themselves, and anything changed since the backup comes back from them.'),
            if (state?.addressText != null) SelectableText(state!.addressText!, style: t.sheetTitle(c.ink)),
          ],
        );
    }
  }
}
