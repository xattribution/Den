import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../../platform/sync/hub_client.dart' show HubException;
import '../../../platform/sync/server_setup.dart';
import '../widgets/nas_picker.dart';

/// Settings → Backups, on a parent's own phone in the server's own family: every night the
/// server backs the family up to its own disk (the newest 14), and to a NAS when one is set up
/// here. Says when the last one was and how big, and plainly when one failed; Back up now; and
/// whose recovery words open them (no passphrase to keep).
class BackupsScreen extends StatefulWidget {
  const BackupsScreen({super.key, this.source, this.now});

  /// The server's side; tests pass a fake.
  final ServerSource? source;

  /// The time, for tests (UTC ms).
  final int? now;

  @override
  State<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends State<BackupsScreen> {
  ServerSource? _source;
  bool _started = false;
  bool _loading = true;
  bool _busy = false;
  bool _notHost = false;
  BackupsState? _state;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final network = context.watch(const {}).network;
    final hasHub = network != null && (network.isHub || network.hubDevice != null);
    _source = widget.source ?? (hasHub ? HubServerSource(network) : null);
    _load();
  }

  void _show(BackupsState s) {
    if (!mounted) return;
    setState(() {
      _state = s;
      _error = null;
    });
    DenScope.read(context).backupProblem = s.problem;
  }

  Future<void> _load() async {
    final source = _source;
    if (source == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      _show(await source.backups());
    } on HubException catch (e) {
      if (mounted) {
        setState(() {
          _notHost = e.code == 'host_family_only';
          _error = _notHost ? null : e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<BackupsState> Function() call) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _show(await call());
    } on HubException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Setting up the NAS, page by page, in place of this page (no route of its own).
  bool _picking = false;

  void _setUpNas() => setState(() => _picking = true);

  Widget _picker() {
    final source = _source!;
    return NasPicker(
      find: source.findNas,
      shares: source.shares,
      finishLabel: 'Use this folder',
      initial: _state?.place,
      onBack: () => setState(() => _picking = false),
      finish: (place) async {
        try {
          final s = await source.setPlace(place);
          _show(s);
          if (mounted) setState(() => _picking = false);
          return null;
        } on HubException catch (e) {
          return e.message;
        }
      },
    );
  }

  int get _now => widget.now ?? DateTime.now().millisecondsSinceEpoch;

  String _lastWords(int at) {
    final when = backupWhen(at, _now);
    final time = DateFormat('h:mm a').format(DateTime.fromMillisecondsSinceEpoch(at));
    return '${when[0].toUpperCase()}${when.substring(1)} at $time';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final t = context.text;
    final own = app.allowsTrust(DenAction.manageFamily) && app.den.thisDevice?.mode == DeviceMode.personal;
    final s = _state;
    final problem = s?.problem;
    final nas = s?.place;
    if (_picking && _source != null) return _picker();
    return DenPage(
      title: 'Backups',
      children: [
        if (!own)
          const NoticeLine(icon: PhosphorIconsRegular.lockKey, message: 'Backups are set up on a parent\'s own phone.')
        else if (_source == null)
          const NoticeLine(icon: PhosphorIconsRegular.info, message: 'This needs the family\'s server.')
        else if (_loading && s == null)
          const NoticeLine(icon: PhosphorIconsRegular.hourglass, message: 'Asking the server')
        else if (_notHost)
          const NoticeLine(icon: PhosphorIconsRegular.lockKey, message: 'Whoever runs your family\'s server looks after its backups.')
        else if (s == null)
          GroupCard(child: ErrorState(message: _error ?? 'Couldn\'t reach the server.', actionLabel: 'Try again', onAction: _load))
        else ...[
          GroupCard(
            child: Column(
              children: ruled([
                InfoRow.text(label: 'Every night', value: 'On the server, keeping the newest ${s.keep}'),
                InfoRow.text(
                  label: 'Last backup',
                  value: s.lastAt == null
                      ? 'None yet'
                      : [_lastWords(s.lastAt!), if (s.lastSize != null) sizeWords(s.lastSize!)].join(' · '),
                ),
              ]),
            ),
          ),
          if (problem != null)
            ErrorState(
              message: backupProblemWords(problem, when: backupWhen(problem.at, _now), nas: nas?.label),
              actionLabel: problem.kind == 'no_words' ? 'Save your recovery words' : 'Back up now',
              onAction: problem.kind == 'no_words' ? () => context.push('/welcome/words') : () => _run(_source!.backUpNow),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: _busy ? null : () => _run(_source!.backUpNow),
                child: Text(_busy || s.running ? 'Backing up' : 'Back up now'),
              ),
            ),
          if (s.opensWith.isNotEmpty)
            Text(tidy('A backup opens with the recovery words of ${s.opensWith.join(' or ')}. There\'s no other password to keep.'),
                style: t.meta(c.ink2)),
          DenSection(
            title: 'On your NAS',
            child: Column(
              children: ruled([
                if (nas == null)
                  NavRow(
                    icon: PhosphorIconsRegular.hardDrives,
                    label: 'Back up to a NAS',
                    detail: 'A copy at home, off the server',
                    onTap: _busy ? null : _setUpNas,
                  )
                else ...[
                  NavRow(
                    icon: PhosphorIconsRegular.hardDrives,
                    label: nas.label,
                    value: '${nas.share}/${nas.folder}',
                    detail: s.placeLastAt == null ? 'No copy yet' : 'Last copy: ${_lastWords(s.placeLastAt!)}',
                    onTap: _busy ? null : _setUpNas,
                  ),
                  NavRow(
                    icon: PhosphorIconsRegular.x,
                    label: 'Stop copying to the NAS',
                    chevron: false,
                    onTap: _busy ? null : () => _run(_source!.clearPlace),
                  ),
                ],
              ], indent: 36),
            ),
          ),
          if (_error != null) Text(tidy(_error!), style: t.body(c.destructive)),
        ],
      ],
    );
  }
}
