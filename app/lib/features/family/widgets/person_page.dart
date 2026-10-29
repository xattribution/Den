import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../state/family_actions.dart';
import '../state/family_needs.dart';
import '../state/trust_actions.dart';
import '../words/family_words.dart';
import '../words/oversight.dart';
import '../words/sitter.dart';
import 'family_parts.dart';
import 'invite_sheet.dart';
import 'person_sheets.dart';
import 'recovery_section.dart';
import 'sitter_sheet.dart';

/// Everything about one person, written as sentences (Family.dc.html's card, then the rest of
/// their page): their picture and who they are, what they may do as switches that say what they
/// change before they save, their birthday and sign-in for shared screens, their devices each
/// with Remove, and removing them from the family.
///
/// Parents see it all; the trust decisions (who someone is, what a kid may do, PINs, devices,
/// removing someone) change only on a parent's own device and say so elsewhere. Everyone else
/// sees who the person is.
class PersonPage extends StatefulWidget {
  const PersonPage({super.key, required this.member});

  final String member;

  @override
  State<PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<PersonPage> {
  /// A switch flipped and waiting for its yes: which, and to what.
  (String, bool)? _asking;
  String? _removingDevice;
  bool _removingPerson = false;
  bool _busy = false;
  String? _error;

  @override
  void didUpdateWidget(PersonPage old) {
    super.didUpdateWidget(old);
    if (old.member != widget.member) {
      _asking = null;
      _removingDevice = null;
      _removingPerson = false;
      _error = null;
    }
  }

  Future<void> _run(Future<Object?> Function() write, {VoidCallback? after}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await tryWrite(write);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
      if (problem == null) {
        _asking = null;
        _removingDevice = null;
        after?.call();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final den = app.den;
    final m = den.member(widget.member);
    if (m == null) return const EmptyState(message: 'This person is no longer in the family.');
    final manage = app.allows(DenAction.manageFamily);
    final trust = app.allowsTrust(DenAction.manageFamily);
    final isMe = app.me?.id == m.id;
    final ended = m.accessEndedOn(app.today);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (manage && !trust) ...[
          const NoticeLine(
            icon: PhosphorIconsRegular.lockKey,
            message: "Who can do what changes only on a parent's own phone, not on a shared screen.",
          ),
          const SizedBox(height: Sp.s),
        ],
        _card(context, app, m, manage: manage, trust: trust),
        if (manage) ...[
          sectionGap,
          _about(context, app, m, trust: trust, isMe: isMe),
          if (ended && trust) ...[sectionGap, AccessEndedNotice(member: m)],
          sectionGap,
          _devices(context, app, m, trust: trust && !ended),
          if (trust && isMe && m.isParent) ...[sectionGap, RecoverySection(member: m)],
          if (trust && !isMe && !_lastParent(den, m)) ...[sectionGap, _remove(context, m)],
        ],
      ],
    );
  }

  static bool _lastParent(Den den, Member m) => m.isParent && den.members.where((x) => x.isParent).length <= 1;

  /// The board's card: name, who they are, Change picture; what their role means; their
  /// switches.
  Widget _card(BuildContext context, AppState app, Member m, {required bool manage, required bool trust}) {
    final c = context.colors;
    final t = context.text;
    final family = app.den.family;
    final switches = <KidSwitchView>[
      if (m.isKid) ...kidSwitches(m, family),
      if (m.role == Role.adult || m.role == Role.guest)
        KidSwitchView(
          KidSwitch.assistant,
          on: (family?.assistant.enabled ?? false) && (family?.assistant.members.contains(m.id) ?? false),
          label: 'Can use the AI helper',
          detail: 'Off until you turn it on',
          reason: (family?.assistant.enabled ?? false) ? null : 'Turn on the AI helper in Settings first',
        ),
    ];
    final who = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(header: true, child: Text(m.name, style: t.section(c.ink).withWeight(FontWeight.w800))),
        const SizedBox(height: 2),
        Text(FamilyWords.memberLine(m, app.today), style: t.meta(c.ink2)),
      ],
    );
    final picture = canChangePicture(app.den.actor, m, family)
        ? OutlinedButton(
            onPressed: () => showPictureSheet(context, m),
            child: const Text('Change picture', maxLines: 1, softWrap: false),
          )
        : null;
    // The button goes under the name once the text is large, so the name never squeezes.
    final large = MediaQuery.textScalerOf(context).scale(1) > 1.35;
    final rows = <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.m),
        child: picture != null && large
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [who, const SizedBox(height: Sp.m), picture])
            : Row(children: [Expanded(child: who), if (picture != null) ...[const SizedBox(width: Sp.m), picture]]),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: Sp.m),
        child: Text(tidy(FamilyWords.roleNow(m.name, m.role)), style: t.meta(c.ink2)),
      ),
    ];
    if (manage) {
      for (final s in switches) {
        final asking = _asking?.$1 == s.which.name ? _asking : null;
        rows.add(const RowRule());
        rows.add(SwitchLine(
          label: s.label,
          detail: s.detail,
          reason: trust ? s.reason : null,
          value: asking?.$2 ?? s.on,
          onChanged: trust && s.changeable && !_busy
              ? (on) => setState(() {
                    _error = null;
                    _asking = on == s.on ? null : (s.which.name, on);
                  })
              : null,
        ));
        rows.add(DenReveal(
          visible: asking != null,
          child: asking == null
              ? const SizedBox(width: double.infinity)
              : ConfirmPanel(
                  message: kidSwitchChange(s.which, m.name, on: asking.$2),
                  confirmLabel: kidSwitchVerb(asking.$2),
                  busy: _busy,
                  error: _error,
                  onConfirm: () {
                    final trustActions = context.trustActions;
                    _run(() => trustActions.setKidSwitch(m, s.which, asking.$2));
                  },
                  onCancel: () => setState(() {
                    _asking = null;
                    _error = null;
                  }),
                ),
        ));
      }
    }
    return GroupCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows));
  }

  /// Who they are, their birthday, and how they sign in on a shared screen.
  Widget _about(BuildContext context, AppState app, Member m, {required bool trust, required bool isMe}) {
    final den = app.den;
    final shared = sharedDisplays(den).isNotEmpty;
    final birthday = m.birthday;
    final pin = signInKindFor(m) == 'pin';
    final signIn = m.signIn.kind == 'none' && m.isParent && shared ? 'Needed' : signInWords(m);
    return DenSection(
      title: 'About ${m.name}',
      child: Column(
        children: ruled([
          NavRow(
            icon: PhosphorIconsRegular.textAa,
            label: 'Name',
            value: m.name,
            onTap: () => showNameSheet(context, m),
          ),
          NavRow(
            icon: PhosphorIconsRegular.identificationCard,
            label: 'Who ${m.name} is',
            value: FamilyWords.memberLine(m, app.today),
            onTap: trust && !isMe ? () => showRoleSheet(context, m) : null,
            chevron: trust && !isMe,
          ),
          if (m.role == Role.guest)
            NavRow(
              icon: PhosphorIconsRegular.calendarX,
              label: 'Has Den',
              value: untilWords(m, app.formats, app.today),
              onTap: trust ? () => showUntilSheet(context, m) : null,
              chevron: trust,
            ),
          NavRow(
            icon: PhosphorIconsRegular.cake,
            label: 'Birthday',
            value: birthday == null ? 'Add' : DateFormat.yMMMMd().format(app.formats.dateTime(birthday)),
            onTap: () => _pickBirthday(context, app, m),
          ),
          NavRow(
            icon: PhosphorIconsRegular.lockKey,
            label: pin ? 'PIN for shared screens' : 'Picture pattern for shared screens',
            value: signIn,
            onTap: trust ? () => showSignInSheet(context, m, canClear: !(m.isParent && shared)) : null,
            chevron: trust,
          ),
        ], indent: 36),
      ),
    );
  }

  Future<void> _pickBirthday(BuildContext context, AppState app, Member m) async {
    final today = app.formats.dateTime(app.today);
    final current = m.birthday == null ? null : app.formats.dateTime(m.birthday!);
    final picked = await showDayPicker(
      context,
      title: '${FamilyWords.possessive(m.name)} birthday',
      initial: current ?? DateTime(today.year - (m.isKid ? 8 : 35), today.month, today.day),
      first: DateTime(1900),
      last: today,
      yearFirst: current == null,
    );
    if (picked == null || !context.mounted) return;
    final family = context.familyActions;
    await attempt(context, () => family.saveDetails(m.id, birthday: DateFormat('yyyy-MM-dd').format(picked)));
  }

  /// Their own phones and tablets, each with Remove; Invite for another.
  Widget _devices(BuildContext context, AppState app, Member m, {required bool trust}) {
    final c = context.colors;
    final den = app.den;
    final devices = devicesOf(den, m.id);
    final rows = <Widget>[];
    for (final d in devices) {
      final isThis = den.thisDevice?.id == d.id;
      final removing = _removingDevice == d.id;
      rows.add(Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Row(
              children: [
                Icon(deviceGlyph(d), size: 22, color: c.ink),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.name, style: context.text.body(c.ink)),
                      Text(isThis ? 'This device' : FamilyWords.deviceKind(d.kind), style: context.text.meta(c.ink2)),
                    ],
                  ),
                ),
                if (trust && !isThis && !removing)
                  TextButton(
                    onPressed: _busy ? null : () => setState(() => _removingDevice = d.id),
                    style: TextButton.styleFrom(foregroundColor: c.destructive),
                    child: const Text('Remove', maxLines: 1, softWrap: false),
                  ),
              ],
            ),
          ),
          DenReveal(
            visible: removing,
            child: !removing
                ? const SizedBox(width: double.infinity)
                : ConfirmPanel(
                    message: '${d.name} stops syncing right away and forgets the family. To use it again, invite it.',
                    confirmLabel: 'Remove ${d.name}',
                    destructive: true,
                    busy: _busy,
                    error: _error,
                    onConfirm: () {
                      final trustActions = context.trustActions;
                      _run(() => trustActions.revokeDevice(d.id));
                    },
                    onCancel: () => setState(() {
                      _removingDevice = null;
                      _error = null;
                    }),
                  ),
          ),
        ],
      ));
    }
    final invite = trust && app.me?.id != m.id;
    return DenSection(
      title: '${FamilyWords.possessive(m.name)} devices',
      trailing: invite && devices.isNotEmpty
          ? SectionLink('Invite', semanticLabel: 'Invite ${m.name} on another device', onTap: () => showInviteSheet(context, memberId: m.id))
          : null,
      child: devices.isEmpty
          ? EmptyState(
              compact: true,
              message: '${m.name} has no devices yet.',
              actionLabel: invite ? 'Invite ${m.name}' : null,
              onAction: invite ? () => showInviteSheet(context, memberId: m.id) : null,
            )
          : Column(children: ruled(rows, indent: 36)),
    );
  }

  /// Removing them, said in place first.
  Widget _remove(BuildContext context, Member m) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_removingPerson)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _removingPerson = true),
              style: TextButton.styleFrom(foregroundColor: c.destructive),
              icon: Icon(PhosphorIconsRegular.trash, size: 20, color: c.destructive),
              label: Text('Remove ${m.name} from the family'),
            ),
          ),
        DenReveal(
          visible: _removingPerson,
          child: !_removingPerson
              ? const SizedBox(width: double.infinity)
              : GroupCard(
                  padding: const EdgeInsets.fromLTRB(DenLayout.cardPadding, Sp.l, DenLayout.cardPadding, 0),
                  child: ConfirmPanel(
                    message:
                        "${m.name} leaves the family and ${FamilyWords.possessive(m.name)} devices stop syncing. This can't be undone.",
                    confirmLabel: 'Remove ${m.name}',
                    destructive: true,
                    busy: _busy,
                    error: _error,
                    onConfirm: () {
                      final trustActions = context.trustActions;
                      _run(() => trustActions.removePerson(m.id), after: () => _removingPerson = false);
                    },
                    onCancel: () => setState(() {
                      _removingPerson = false;
                      _error = null;
                    }),
                  ),
                ),
        ),
      ],
    );
  }
}
