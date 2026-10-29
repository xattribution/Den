import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';

import '../platform/calendars/device_calendar_source.dart';
import '../platform/calendars/phone_calendars.dart';
import '../platform/notifications/reminder_scheduler.dart';
import '../platform/storage/boot.dart';
import '../platform/storage/memberships.dart';
import '../platform/sync/den_network.dart';
import '../platform/sync/net_pairing.dart';
import '../platform/sync/pairing.dart';
import 'app_state.dart';

export '../platform/storage/memberships.dart' show Membership, MembershipKind, Memberships;

/// One family open on this device: its engine's [state] (its own keys, log, change counter and
/// sync) and the [pairing] that goes through its connection.
class FamilyLog {
  FamilyLog({required this.membership, required this.state, PairingService? pairing})
      : pairing = pairing ?? (state.network == null ? null : NetPairing(state.network!));

  /// Where this device keeps it, and what it knew of it when it last looked.
  Membership membership;

  final AppState state;

  /// Joining, inviting and recovery for this family, over its own connection; null where the
  /// app's own ([Pairing.of]) does (tests, the demo family).
  final PairingService? pairing;

  Den get den => state.den;

  DenNetwork? get network => state.network;

  /// The family's id: the log's.
  String get id => den.familyId ?? membership.id;

  /// The family's name as its people see it.
  String get name => den.family?.name ?? membership.label ?? 'Your family';

  /// The color of the family's source tag on this device ("All my families"); null for ink.
  Marker? get color => Marker.parse(membership.color);

  /// Asked to join, and a parent hasn't let this device in yet.
  bool get waiting => den.hasFamily && !den.isApproved;

  /// Whether [id] names this family: its family id, compared as den_core writes them (lower
  /// case), so an upper-case twin of an id this device holds is this family, never another.
  bool isId(String id) {
    final want = id.toLowerCase();
    return want == this.id.toLowerCase() || want == membership.id.toLowerCase();
  }

  @override
  String toString() => 'FamilyLog($id, $name)';
}

/// How a household's logs are opened, kept and let go of on this device. The app's is
/// [DeviceHouseholdStore]; tests keep everything in memory.
abstract class HouseholdStore {
  /// Opens [log]'s engine, connection and state. With [fresh], a new engine with new keys for a
  /// family this device is about to join, clearing whatever an earlier try left under its name.
  Future<FamilyLog> open(Membership log, {bool fresh = false});

  /// Deletes what this device kept for [log] (its change log, keys and settings), once its
  /// engine is closed.
  Future<void> forget(Membership log);

  /// Saves the list of logs and what the device shows ([Memberships.all] or a log's id).
  Future<void> save(List<Membership> logs, String? active);
}

/// The families this device holds, which one it shows, and "All my families" (FAMILY-LINKS-PLAN
/// §4.1, §4.6). Each family is a [FamilyLog] with its own engine and keys: a family's keys, data
/// and tokens never meet another's on this device, and the device holds at most one engine per
/// family.
///
/// A device in one family has one log and no list ([Memberships]): it looks and runs exactly as
/// Den always has. The list is written when a second family joins.
class Household extends ChangeNotifier {
  Household(List<FamilyLog> logs, {this.store, String? active})
      : assert(logs.isNotEmpty),
        _logs = [...logs] {
    _active = _logs.firstWhere((l) => active != null && l.isId(active), orElse: () => _firstFamily);
    _all = active == Memberships.all;
    for (final l in _logs) {
      _watch(l);
    }
  }

  /// A household of [state]'s family alone: tests, and anything made before households.
  factory Household.single(AppState state, {PairingService? pairing}) => Household([
        FamilyLog(membership: Membership(id: state.den.familyId ?? 'family', primary: true), state: state, pairing: pairing),
      ]);

  /// Opens the logs this device holds: the first family as Den always kept it, and each other
  /// one the list names. A family whose log or keys didn't survive (cleared storage) is let go,
  /// unless nothing else is left; then the first log opens empty, for the welcome screen.
  static Future<Household> boot(HouseholdStore store) async {
    final listed = await Memberships.load();
    if (listed.isEmpty) {
      return Household([await store.open(const Membership(id: 'family', primary: true))], store: store);
    }
    final logs = <FamilyLog>[];
    final gone = <Membership>[];
    final unopened = <Membership>[];
    for (final m in listed) {
      try {
        final log = await store.open(m);
        if (log.den.hasFamily) {
          logs.add(log);
        } else {
          await _close(log);
          gone.add(m);
        }
      } on Object catch (e) {
        // Kept in the list (its keychain may just not be readable yet), and its reminders stay.
        unopened.add(m);
        debugPrint("Den couldn't open the family ${m.label ?? m.id}: $e");
      }
    }
    for (final m in gone) {
      // The first log's storage stays Den's own, to start over in; nothing another family is
      // kept under is ever deleted.
      if (!m.primary && !listed.any((o) => !identical(o, m) && o.sharesStorageWith(m))) await store.forget(m);
    }
    if (logs.isEmpty) {
      final first = listed.firstWhere((m) => m.primary, orElse: () => const Membership(id: 'family', primary: true));
      logs.add(await store.open(first));
      unopened.removeWhere((m) => identical(m, first));
    }
    final household = Household(logs, store: store, active: await Memberships.loadActive()).._unopened.addAll(unopened);
    if (gone.isNotEmpty) await household._persist();
    return household;
  }

  final HouseholdStore? store;
  final List<FamilyLog> _logs;
  late FamilyLog _active;
  bool _all = false;

  /// Families this device holds whose engine didn't open this time (a keychain not readable
  /// yet): still listed, and their reminders are left with the OS until they open again.
  List<Membership> get unopened => List.unmodifiable(_unopened);
  final List<Membership> _unopened = [];

  /// Families being prepared right now, by id: a second prepare of one waits for none and is
  /// refused, so two can never wipe each other.
  final Set<String> _pending = {};
  final Map<FamilyLog, VoidCallback> _watching = {};
  bool _disposed = false;

  /// Every log open on this device.
  List<FamilyLog> get logs => List.unmodifiable(_logs);

  /// The families in the switcher: the logs that hold one (a family left, or not yet joined,
  /// has none).
  List<FamilyLog> get families => [for (final l in _logs) if (l.den.hasFamily) l];

  /// Whether this device holds two families or more: then the switcher and "All my families"
  /// appear. With one, the app is exactly what it always was.
  bool get several => families.length > 1;

  /// The family the device shows (and, in "All my families", the one Chores, Stars, Family,
  /// Settings and Ask stay with).
  FamilyLog get active => _active;

  /// Whether "All my families" is showing: Today, Calendar and Lists from every family.
  bool get showingAll => _all && several;

  /// The open log of the family [id], or null.
  FamilyLog? byId(String id) {
    for (final l in _logs) {
      if (l.isId(id)) return l;
    }
    return null;
  }

  /// The log that holds [den], or null.
  FamilyLog? of(Den den) {
    for (final l in _logs) {
      if (identical(l.den, den)) return l;
    }
    return null;
  }

  FamilyLog get _firstFamily =>
      _logs.firstWhere((l) => l.den.isApproved, orElse: () => _logs.firstWhere((l) => l.den.hasFamily, orElse: () => _logs.first));

  /// Shows [log]'s family, at once; the device remembers it (done when the future completes).
  Future<void> choose(FamilyLog log) async {
    if (!_logs.contains(log) || (identical(log, _active) && !_all)) return;
    _active = log;
    _all = false;
    _changed();
    await _saveActive();
  }

  /// Shows "All my families", at once; the device remembers it.
  Future<void> chooseAll() async {
    if (!several || _all) return;
    _all = true;
    _changed();
    await _saveActive();
  }

  /// Starts an engine for the family [familyId] that this device is about to join through the
  /// hub at [hub], with new keys of its own, kept under a fresh random slot. It isn't one of
  /// [logs] until [adopt] takes it in; [discard] lets it go. Throws [StateError] when this device
  /// already holds the family, or is preparing it, or when [familyId] isn't a family id as
  /// den_core makes them (an upper-case twin of one included): one engine per family. Anything
  /// that fails once the log was made deletes it again.
  Future<FamilyLog> prepare(String familyId, {Uri? hub, String? label}) async {
    final store = this.store;
    if (store == null) throw StateError('This device can\'t hold another family');
    if (!Membership.validId(familyId)) throw StateError('That isn\'t a family Den knows how to keep');
    if (byId(familyId) != null || _unopened.any((m) => m.id == familyId)) {
      throw StateError('This device is in that family already');
    }
    if (!_pending.add(familyId)) throw StateError('This device is joining that family already');
    String slot;
    do {
      slot = Membership.newSlot();
    } while (_logs.any((l) => l.membership.slot == slot) || _unopened.any((m) => m.slot == slot));
    final membership = Membership(
      id: familyId,
      hub: hub == null ? null : Uri(scheme: hub.scheme, host: hub.host, port: hub.hasPort ? hub.port : null).toString(),
      label: label,
      color: _freeColor().name,
      slot: slot,
    );
    try {
      return await store.open(membership, fresh: true);
    } catch (_) {
      _pending.remove(familyId);
      try {
        await store.forget(membership);
      } on Object {
        // Nothing more to take away.
      }
      rethrow;
    }
  }

  /// Takes in [log], prepared for a family this device asked to join, once the request went
  /// out: it is listed and saved, and the device shows it.
  Future<void> adopt(FamilyLog log) async {
    if (_logs.contains(log)) return;
    // Joining may still be under way (no family yet); a family it holds must be the one it was
    // made for.
    final joined = log.den.familyId;
    if (joined != null && joined != log.membership.id) {
      throw StateError('That engine joined another family than the one it was made for');
    }
    if (byId(log.id) != null) throw StateError('This device is in that family already');
    _pending.remove(log.membership.id);
    // The first family gets the color its tag had all along: the first one.
    final first = _logs.where((l) => l.membership.primary).firstOrNull;
    if (first != null && first.membership.color == null && _logs.length == 1) {
      first.membership = first.membership.copyWith(color: Marker.values.first.name);
    }
    _logs.add(log);
    _watch(log);
    _active = log;
    _all = false;
    await _persist();
    _changed();
  }

  /// Lets go of a log [prepare] made that didn't join after all: closes it and deletes it (a
  /// join request that reached the family is taken back first by whoever sent it:
  /// `AnotherFamilyPairing`).
  Future<void> discard(FamilyLog log) async {
    if (_logs.contains(log)) return remove(log);
    _pending.remove(log.membership.id);
    await _close(log);
    if (!_logs.any((l) => l.membership.sharesStorageWith(log.membership))) await store?.forget(log.membership);
  }

  /// Takes [log] off this device: closes its engine and connection and deletes its log, keys
  /// and settings. The device shows another family. A household never drops its last log.
  Future<void> remove(FamilyLog log) async {
    if (!_logs.contains(log) || _logs.length == 1) return;
    _unwatch(log);
    _logs.remove(log);
    if (identical(_active, log)) {
      _active = _firstFamily;
      if (!several) _all = false;
    }
    if (!several) _all = false;
    await _persist();
    _changed();
    // After the screens moved off it: a frame may still draw it as it goes.
    await Future<void>.delayed(Duration.zero);
    await _close(log);
    // Never what another family is kept under.
    if (!_logs.any((l) => l.membership.sharesStorageWith(log.membership))) await store?.forget(log.membership);
  }

  Marker _freeColor() {
    final used = {for (final l in _logs) l.membership.color ?? (l.membership.primary ? Marker.values.first.name : null)};
    return Marker.values.firstWhere((m) => !used.contains(m.name), orElse: () => Marker.values[_logs.length % Marker.values.length]);
  }

  void _watch(FamilyLog log) {
    var had = log.den.hasFamily;
    var approved = log.den.isApproved;
    var name = log.den.family?.name;
    void check() {
      if (_disposed) return;
      if (log.den.isApproved != approved) {
        approved = log.den.isApproved;
        _changed();
      }
      final now = log.den.hasFamily;
      if (had && !now && _logs.length > 1 && _logs.contains(log)) {
        // A family this device left (start over, or its access ended and it started over)
        // while it holds another: the empty log goes, and another family shows.
        had = now;
        unawaited(remove(log));
        return;
      }
      if (now != had) {
        had = now;
        _changed();
      }
      final current = log.den.family?.name;
      if (current != null && current != name) {
        name = current;
        if (log.membership.label != current) {
          log.membership = log.membership.copyWith(label: current);
          if (_logs.length > 1) unawaited(_persist());
        }
        _changed();
      }
    }

    _watching[log] = check;
    log.state.addListener(check);
  }

  void _unwatch(FamilyLog log) {
    final check = _watching.remove(log);
    if (check != null) log.state.removeListener(check);
  }

  static Future<void> _close(FamilyLog log) async {
    final network = log.network;
    if (network != null) await network.close();
    try {
      await log.den.close();
    } on Object {
      // Closing twice, or a log already gone.
    }
  }

  /// Saves the list once there is more than one log; a device back to one keeps its list, so
  /// the names stay whose they are.
  Future<void> _persist() async {
    final store = this.store;
    if (store == null) return;
    for (final l in _logs) {
      final id = l.den.familyId;
      var m = l.membership;
      // The first log was listed by no id until now: it takes its family's.
      if (m.primary && id != null && m.id != id) {
        m = Membership(id: id, primary: true, hub: m.hub, label: m.label, color: m.color);
      }
      l.membership = m.copyWith(label: l.den.family?.name);
    }
    // A family that didn't open this time stays listed.
    await store.save([for (final l in _logs) l.membership, ..._unopened], _activeChoice);
  }

  String? get _activeChoice => showingAll ? Memberships.all : _active.id;

  Future<void> _saveActive() async {
    if (_logs.length + _unopened.length < 2) return;
    await store?.save([for (final l in _logs) l.membership, ..._unopened], _activeChoice);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final l in [..._watching.keys]) {
      _unwatch(l);
    }
    super.dispose();
  }

  /// The household above [context], or null where there is none (screens tested alone).
  static Household? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HouseholdScope>()?.notifier;

  /// The household above [context] without rebuilding it: for callbacks.
  static Household? read(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<HouseholdScope>()?.widget as HouseholdScope?)?.notifier;
}

/// Makes the [Household] available below it, rebuilding readers when its families or the
/// choice change.
class HouseholdScope extends InheritedNotifier<Household> {
  const HouseholdScope({super.key, required Household household, required super.child}) : super(notifier: household);
}

/// The device's own [HouseholdStore]: each family's change log, keys and settings where
/// [Membership] says, through [Boot].
class DeviceHouseholdStore implements HouseholdStore {
  DeviceHouseholdStore({required this.device, this.reminders, this.phoneCalendars = false});

  /// How the device looks, shared by every family on it.
  final DevicePrefs device;

  /// The device's reminders, one budget across every family.
  final ReminderScheduler? reminders;

  /// Whether the first family brings in this phone's own calendars.
  final bool phoneCalendars;

  @override
  Future<FamilyLog> open(Membership log, {bool fresh = false}) async {
    if (fresh) {
      // Nothing an earlier try left under these names: settings included.
      await DenNetwork.forget(log);
      await AppState.forget(log.pref);
    }
    final den = fresh ? await Boot.startFresh(log) : await Boot.startLog(log);
    final network = await DenNetwork.load(den, log: log.primary ? null : log);
    final calendars = log.primary && phoneCalendars && PhoneCalendars.supported ? PhoneCalendars(den, DeviceCalendarSource()) : null;
    final state = await AppState.load(
      den,
      network: network,
      reminders: reminders,
      phoneCalendars: calendars,
      device: device,
      key: log.primary ? null : log.pref,
    );
    return FamilyLog(membership: log, state: state);
  }

  @override
  Future<void> forget(Membership log) async {
    await Boot.forgetLog(log);
    await DenNetwork.forget(log);
    await AppState.forget(log.pref);
  }

  @override
  Future<void> save(List<Membership> logs, String? active) async {
    await Memberships.save(logs);
    await Memberships.saveActive(active);
  }
}
