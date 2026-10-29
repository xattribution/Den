import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/pickers/time_zone_picker.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../family/family.dart';
import '../../rewards/rewards.dart' show PointsSwitch;
import '../widgets/family_colors_choice.dart';
import '../widgets/hub_help_switch.dart';

/// Settings → Family: the family's name, time zone and first day of the week, the family's
/// colors (each pack shown with the family's own people), whether it uses points (the rewards'
/// [PointsSwitch]), and whether what Den reads from a photo or a message is added right away or
/// shown first. Each saves as it changes.
class FamilySettingsScreen extends StatefulWidget {
  const FamilySettingsScreen({super.key});

  @override
  State<FamilySettingsScreen> createState() => _FamilySettingsScreenState();
}

class _FamilySettingsScreenState extends State<FamilySettingsScreen> {
  late final TextEditingController _name = TextEditingController(text: DenScope.read(context).den.family?.name ?? '');
  final _focus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _saveName();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Also runs when the field loses focus, which can happen as the page closes: it reads the
  /// engine without depending on it, and only while this page is still here.
  Future<void> _saveName() async {
    if (!mounted) return;
    final den = DenScope.read(context).den;
    final name = _name.text.trim();
    if (name.isEmpty || name == den.family?.name) return;
    await _write(() => context.familyActions.rename(name));
  }

  Future<void> _write(Future<ActionResult> Function() write) async {
    final problem = await tryWrite(write);
    if (mounted) setState(() => _error = problem);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final t = context.text;
    final family = app.den.family;
    if (family == null || !app.allows(DenAction.manageFamily)) {
      return const DenPage(title: 'Family', children: [EmptyState(message: 'Only parents change the family\'s settings.')]);
    }
    final actions = context.familyActions;
    return DenPage(
      title: 'Family',
      children: [
        if (_error != null) ErrorState(message: _error!, actionLabel: 'OK', onAction: () => setState(() => _error = null)),
        LabeledField(
          label: 'Family name',
          child: TextField(
            controller: _name,
            focusNode: _focus,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            style: t.body(c.ink),
            onSubmitted: (_) => _saveName(),
          ),
        ),
        GroupCard(
          child: NavRow(
            icon: PhosphorIconsRegular.globeHemisphereWest,
            label: 'Time zone',
            value: zoneLabel(family.timezone),
            onTap: () async {
              final zone = await showTimeZoneSheet(context, family.timezone);
              if (zone != null && zone != family.timezone) await _write(() => actions.setTimeZone(zone));
            },
          ),
        ),
        DenSection(
          title: 'Weeks start on',
          child: ChoiceRows<int>(
            choices: const [Choice(0, 'Sunday'), Choice(1, 'Monday')],
            value: family.weekStart,
            onChanged: (d) => _write(() => actions.setWeekStart(d)),
          ),
        ),
        DenSection(
          title: 'Family colors',
          child: FamilyColorsChoice(
            people: app.den.members,
            value: family.colors,
            onChanged: (pack) => _write(() => actions.setColors(pack)),
          ),
        ),
        const GroupCard(child: PointsSwitch()),
        DenSection(
          title: 'When Den reads a photo or message',
          child: ChoiceRows<bool>(
            choices: const [
              Choice(false, 'Add right away', detail: 'With Undo, in case it read something wrong'),
              Choice(true, 'Show me first', detail: 'You look over what it found, then add it'),
            ],
            value: family.captureNeedsReview,
            onChanged: (review) => _write(() => actions.setCaptureReview(review)),
          ),
        ),
        const Ungapped(RecoveryWordsReminder()),
        const Ungapped(HubHelpSwitch()),
      ],
    );
  }
}
