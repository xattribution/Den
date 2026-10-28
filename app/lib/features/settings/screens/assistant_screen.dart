import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/hub_client.dart';
import '../../family/family.dart';
import '../state/assistant_hub.dart';

/// What the AI helper shares, in plain words, for [company] (null: a computer at home).
String assistantPrivacy(String? company) => company == null
    ? 'The AI helper runs on a computer at home, so nothing you type or say leaves your house. It only sees '
        "what you can see in Den: never PINs, and never someone else's private calendar. Den keeps no copy of the "
        'conversation.'
    : 'When the AI helper is on, what you type or say goes to $company so it can answer. So do your family\'s first '
        "names, today's and this week's plans, your list names, and whatever it looks up for you. It only sees what "
        "you can see in Den: never PINs, and never someone else's private calendar. Den keeps no copy of the "
        'conversation. Choose "A computer at home" and nothing leaves your house.';

/// Settings → AI helper, for parents on their own device: on or off for the family (off until a
/// parent turns it on), who besides parents may use it, a kid's daily limit, the month's budget
/// and what's been spent, and who runs it, with its key kept on the hub. What it shares says
/// itself in plain words. The "Add or ask" helper itself comes later.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, this.source});

  /// The hub's setup, for tests; by default the family's hub.
  final AssistantSource? source;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  AssistantSource? _source;
  AssistantSetup? _setup;
  String? _hubError;
  bool _started = false;

  /// A change waiting for its yes: 'enabled' or a member id, and to what.
  (String, bool)? _asking;
  bool _busy = false;
  String? _error;

  String? _provider;
  final _key = TextEditingController();
  bool _useCaptureKey = false;
  String? _saveError;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final network = context.watch(const {}).network;
    final hasHub = network != null && (network.isHub || network.hubDevice != null);
    _source = widget.source ?? (hasHub ? AssistantHub(network) : null);
    _load();
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final source = _source;
    if (source == null) return;
    try {
      final setup = await source.status();
      if (mounted) {
        setState(() {
          _setup = setup;
          _provider ??= setup.provider;
          _useCaptureKey = setup.keyFromCapture;
          _hubError = null;
        });
      }
    } on HubException catch (e) {
      if (mounted) setState(() => _hubError = e.message);
    }
  }

  Future<void> _policy(AssistantPolicy policy) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final trust = context.trustActions;
    final problem = await tryWrite(() => trust.setAssistant(policy));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
      if (problem == null) _asking = null;
    });
  }

  AssistantPolicy _with(AssistantPolicy p, {bool? enabled, Set<String>? members, int? limit, int? budget}) => AssistantPolicy(
        enabled: enabled ?? p.enabled,
        members: members ?? p.members,
        kidDailyLimit: limit ?? p.kidDailyLimit,
        budgetCents: budget ?? p.budgetCents,
      );

  Future<void> _saveProvider() async {
    final provider = _provider;
    final source = _source;
    if (source == null) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final key = _key.text.trim();
      final setup = await source.configure(
        provider: provider,
        key: provider == 'ollama' ? null : key,
        useCaptureKey: provider == 'anthropic' && _useCaptureKey && key.isEmpty,
        baseUrl: provider == 'ollama' ? key : null,
      );
      if (!mounted) return;
      _key.clear();
      setState(() => _setup = setup);
    } on HubException catch (e) {
      if (mounted) setState(() => _saveError = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final t = context.text;
    if (!app.allows(DenAction.manageFamily)) {
      return const DenPage(title: 'AI helper', children: [EmptyState(message: 'Only parents choose who can use the AI helper.')]);
    }
    final trust = app.allowsTrust(DenAction.manageFamily);
    final policy = app.den.family?.assistant ?? const AssistantPolicy();
    final setup = _setup;
    final company = assistantCompany(setup?.provider ?? _provider) ?? (setup?.provider == 'ollama' ? null : 'Anthropic, or the company you choose');
    final asking = _asking;

    Widget confirm(String key, String message, bool on) => DenReveal(
          visible: asking?.$1 == key,
          child: asking?.$1 != key
              ? const SizedBox(width: double.infinity)
              : ConfirmPanel(
                  message: message,
                  confirmLabel: on ? 'Turn on' : 'Turn off',
                  busy: _busy,
                  error: _error,
                  onConfirm: () => _policy(key == 'enabled'
                      ? _with(policy, enabled: on)
                      : _with(policy, members: on ? {...policy.members, key} : ({...policy.members}..remove(key)))),
                  onCancel: () => setState(() => _asking = null),
                ),
        );

    final eligible = [
      for (final m in app.den.members)
        if (!m.isParent && m.tier != Tier.preReader && m.tier != Tier.little) m,
    ];

    return DenPage(
      title: 'AI helper',
      children: [
        if (!trust)
          const NoticeLine(
            icon: PhosphorIconsRegular.lockKey,
            message: "The AI helper is set up only on a parent's own phone, not on a shared screen.",
          ),
        GroupCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchLine(
                label: 'AI helper',
                detail: policy.enabled ? 'On for parents, and anyone you choose below' : 'Off for everyone until you turn it on',
                value: asking?.$1 == 'enabled' ? asking!.$2 : policy.enabled,
                onChanged: trust && !_busy
                    ? (on) => setState(() {
                          _error = null;
                          _asking = on == policy.enabled ? null : ('enabled', on);
                        })
                    : null,
              ),
              confirm(
                'enabled',
                asking?.$2 ?? false
                    ? 'Parents can ask it to add and find things. ${assistantPrivacy(company)}'
                    : 'Nobody in the family will see the AI helper.',
                asking?.$2 ?? false,
              ),
            ],
          ),
        ),
        DenSection(
          title: 'What it shares',
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.l),
            child: Text(assistantPrivacy(company), style: t.body(c.ink)),
          ),
        ),
        if (policy.enabled) ...[
          DenSection(
            title: 'Who can use it',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...ruled([
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 64),
                    child: Row(
                      children: [
                        FaceStack(faces: [for (final m in app.den.members) if (m.isParent) DenAvatar(m, size: 26)]),
                        const SizedBox(width: Sp.m),
                        Expanded(child: Text('Parents, always', style: t.body(c.ink))),
                      ],
                    ),
                  ),
                  for (final m in eligible)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SwitchLine(
                          leading: DenAvatar(m, size: 32),
                          label: m.name,
                          detail: m.isKid ? 'Up to ${policy.kidDailyLimit} questions a day' : null,
                          value: asking?.$1 == m.id ? asking!.$2 : policy.members.contains(m.id),
                          onChanged: trust && !_busy
                              ? (on) => setState(() {
                                    _error = null;
                                    _asking = on == policy.members.contains(m.id) ? null : (m.id, on);
                                  })
                              : null,
                        ),
                        confirm(m.id, kidSwitchChange(KidSwitch.assistant, m.name, on: asking?.$2 ?? false), asking?.$2 ?? false),
                      ],
                    ),
                ]),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
            child: Text("Kids under 9 don't get the AI helper.", style: t.meta(c.ink2)),
          ),
          DenSection(
            title: 'Limits',
            child: Column(
              children: ruled([
                _Count(
                  label: 'Questions a kid can ask a day',
                  value: '${policy.kidDailyLimit}',
                  onLess: trust && policy.kidDailyLimit > 1 ? () => _policy(_with(policy, limit: policy.kidDailyLimit - 5 < 1 ? 1 : policy.kidDailyLimit - 5)) : null,
                  onMore: trust && policy.kidDailyLimit < 200 ? () => _policy(_with(policy, limit: policy.kidDailyLimit + 5)) : null,
                ),
                _Count(
                  label: 'Budget a month',
                  value: dollars(policy.budgetCents),
                  detail: setup == null ? null : 'About ${dollars(setup.spentCents)} of ${dollars(policy.budgetCents)} this month',
                  onLess: trust && policy.budgetCents > 100 ? () => _policy(_with(policy, budget: policy.budgetCents - 100)) : null,
                  onMore: trust && policy.budgetCents < 10000 ? () => _policy(_with(policy, budget: policy.budgetCents + 100)) : null,
                ),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
            child: Text("It stops for the month when the budget is spent.", style: t.meta(c.ink2)),
          ),
        ],
        _runs(context, trust: trust),
      ],
    );
  }

  /// Who runs it: the company and its key, kept on the hub.
  Widget _runs(BuildContext context, {required bool trust}) {
    final c = context.colors;
    final t = context.text;
    if (_source == null) {
      return DenSection(
        title: 'Who runs it',
        child: EmptyState(
          compact: true,
          message: "The AI helper runs through the family's hub, which keeps its key. Set one up first.",
          actionLabel: 'Hub and sync',
          onAction: () => context.push('/settings/advanced/hub'),
        ),
      );
    }
    final setup = _setup;
    if (setup == null) {
      return DenSection(
        title: 'Who runs it',
        child: _hubError != null
            ? ErrorState(message: _hubError!, actionLabel: 'Try again', onAction: _load)
            : Padding(padding: const EdgeInsets.symmetric(vertical: Sp.l), child: Text('Asking the hub', style: t.body(c.ink2))),
      );
    }
    final current = setup.provider;
    final chosen = _provider;
    final changed = chosen != current || _key.text.trim().isNotEmpty;
    final needsKey = chosen != null && chosen != 'ollama' && !(chosen == current && setup.keySaved) && !(chosen == 'anthropic' && _useCaptureKey);
    return DenSection(
      title: 'Who runs it',
      carded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NoticeLine(
            icon: PhosphorIconsRegular.hardDrives,
            message: current == null
                ? 'Nobody yet. Choose who runs it and give the hub its key.'
                : '${assistantNames[current] ?? current} runs it.${setup.keySaved && current != 'ollama' ? ' Its key is on the hub.' : ''}',
          ),
          const SizedBox(height: Sp.s),
          GroupCard(
            child: ChoiceRows<String?>(
              choices: [for (final e in assistantProviders.entries) Choice(e.key, e.value)],
              value: chosen,
              onChanged: trust ? (p) => setState(() => _provider = p) : null,
            ),
          ),
          if (chosen != null && trust) ...[
            const SizedBox(height: Sp.l),
            if (chosen == 'anthropic')
              GroupCard(
                child: SwitchLine(
                  label: 'Use the key for reading photos',
                  detail: 'The Claude key the hub already has',
                  value: _useCaptureKey,
                  onChanged: (v) => setState(() => _useCaptureKey = v),
                ),
              ),
            if (chosen == 'ollama' || !(chosen == 'anthropic' && _useCaptureKey)) ...[
              if (chosen == 'anthropic') const SizedBox(height: Sp.l),
              LabeledField(
                label: chosen == 'ollama'
                    ? "The home computer's address"
                    : chosen == current && setup.keySaved
                        ? 'A new key, to replace the one on the hub'
                        : 'Its API key, kept on the hub',
                error: _saveError,
                child: TextField(
                  controller: _key,
                  obscureText: chosen != 'ollama',
                  autocorrect: false,
                  enableSuggestions: false,
                  style: t.body(c.ink),
                  decoration: InputDecoration(hintText: chosen == 'ollama' ? setup.baseUrl ?? 'http://192.168.1.20:11434' : null),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ] else if (_saveError != null)
              Padding(padding: const EdgeInsets.only(top: Sp.s), child: Text(_saveError!, style: t.meta(c.destructive))),
            const SizedBox(height: Sp.l),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _saving || !(changed || (chosen == 'anthropic' && _useCaptureKey != setup.keyFromCapture)) || (needsKey && _key.text.trim().isEmpty)
                    ? null
                    : _saveProvider,
                child: const Text('Save on the hub'),
              ),
            ),
          ],
          if (current != null && trust) ...[
            const SizedBox(height: Sp.s),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _saving
                    ? null
                    : () {
                        setState(() => _provider = null);
                        _saveProvider();
                      },
                style: TextButton.styleFrom(foregroundColor: c.destructive),
                child: const Text('Forget the key on the hub'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A number to step: its label, the value, and minus and plus as round buttons.
class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value, this.detail, this.onLess, this.onMore});

  final String label;
  final String value;
  final String? detail;
  final VoidCallback? onLess;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Semantics(
      container: true,
      label: '$label, $value',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.s),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: t.body(c.ink)),
                    if (detail != null) Text(detail!, style: t.meta(c.ink2)),
                  ],
                ),
              ),
              RoundButton(icon: PhosphorIconsBold.minus, label: 'Less', onTap: onLess, fill: c.fill, color: c.ink, size: Targets.adult),
              SizedBox(width: 56, child: Text(value, textAlign: TextAlign.center, style: t.rowTitle(c.ink))),
              RoundButton(icon: PhosphorIconsBold.plus, label: 'More', onTap: onMore, fill: c.fill, color: c.ink, size: Targets.adult),
            ],
          ),
        ),
      ),
    );
  }
}
