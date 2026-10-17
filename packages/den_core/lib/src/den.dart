import 'dart:async';

import 'change.dart';
import 'model.dart';
import 'storage.dart';
import 'views.dart';

/// A reminder that comes due in a window, computed from synced data. Devices schedule these as
/// local notifications; the hub sends them through its notifiers.
class ReminderDue {
  const ReminderDue({
    required this.key,
    required this.at,
    required this.title,
    required this.body,
    required this.members,
  });

  /// Stable across devices, so the same reminder is never shown twice: `"<type>:<id>:<when>:<offset>"`.
  final String key;

  /// UTC milliseconds the reminder fires.
  final int at;
  final String title;
  final String body;

  /// Who it is for; empty means everyone who can see the item.
  final List<String> members;
}

/// The engine. One instance per device: it holds the change log, merges changes from any device,
/// enforces permissions, and answers every question the UI, the hub and MCP ask.
///
/// Reads are synchronous over materialized state. Writes are validated against [can] for the
/// current [actor] first (throwing [PermissionDenied] or [InvalidInput]), then signed, stored
/// and applied, and [onChange] fires.
class Den {
  Den._();

  // ---------------------------------------------------------------- lifecycle and identity

  /// Loads the device's log and metadata from [storage] and materializes state.
  static Future<Den> open({
    required DenStorage storage,
    required DeviceKeys keys,
    int Function()? now,
  }) =>
      throw UnimplementedError();

  String get deviceId => throw UnimplementedError();
  DeviceKeys get keys => throw UnimplementedError();
  String? get familyId => throw UnimplementedError();
  bool get hasFamily => familyId != null;

  /// Whether this device's join request has been approved by a parent's device.
  bool get isApproved => throw UnimplementedError();
  Device? get thisDevice => throw UnimplementedError();

  /// The owner of a personal device.
  Member? get owner => throw UnimplementedError();

  /// Who changes are made as right now: the owner on a personal device; on a shared display, the
  /// member who verified within the acting window, else null (open check-off rules apply).
  Member? get actor => throw UnimplementedError();

  /// UTC milliseconds when the acting window on a shared device ends, or null.
  int? get actingUntil => throw UnimplementedError();

  /// Sets who is acting on a shared device after [verifySignIn] succeeded; null ends it.
  void actAs(String? memberId, {Duration window = const Duration(seconds: 60)}) =>
      throw UnimplementedError();

  /// Checks a PIN or picture pattern against the member's sign-in for shared screens.
  Future<bool> verifySignIn(String memberId, String secret) => throw UnimplementedError();

  /// Writes the genesis changes: the family, the founding parent and this device, approved.
  Future<void> createFamily({
    required String familyName,
    required String timezone,
    required String yourName,
    required Marker marker,
    required Animal animal,
    required String deviceName,
    required DeviceKind deviceKind,
    DeviceMode mode = DeviceMode.personal,
  }) =>
      throw UnimplementedError();

  /// Records the family this device is joining and writes its own unapproved device record.
  /// [founderPubkey] comes from the QR code or the pairing session and roots trust.
  Future<void> requestJoin({
    required String familyId,
    required String founderPubkey,
    required String deviceName,
    required DeviceKind kind,
    DeviceMode mode = DeviceMode.personal,
    String? memberId,
  }) =>
      throw UnimplementedError();

  /// Fires with the record types that changed after every local write or ingest.
  Stream<Set<String>> get onChange => throw UnimplementedError();

  // ---------------------------------------------------------------- family state

  Family? get family => throw UnimplementedError();

  /// Members in display order, removed members excluded.
  List<Member> get members => throw UnimplementedError();
  Member? member(String id) => throw UnimplementedError();
  List<Device> get devices => throw UnimplementedError();
  Device? device(String id) => throw UnimplementedError();

  /// Devices waiting for a parent's approval.
  List<Device> get pendingDevices => throw UnimplementedError();
  List<Category> get categories => throw UnimplementedError();
  Category? category(String id) => throw UnimplementedError();

  /// Today's local date in the family's time zone, `YYYY-MM-DD`.
  String todayDate() => throw UnimplementedError();

  Future<void> updateFamily(Map<String, Object?> patch) => throw UnimplementedError();

  Future<String> addMember({
    required String name,
    required Role role,
    Tier? tier,
    Marker marker = Marker.blue,
    Animal animal = Animal.cat,
    String? birthday,
    Set<Grant> grants = const {},
  }) =>
      throw UnimplementedError();

  Future<void> updateMember(String id, Map<String, Object?> patch) => throw UnimplementedError();
  Future<void> removeMember(String id) => throw UnimplementedError();

  /// Sets how a member signs in on shared screens: `pin` (4 digits), `pattern` (4 animals as
  /// digits 0-8), or `none`. Secrets are salted and hashed before they're written.
  Future<void> setSignIn(String memberId, {required String kind, String? secret}) =>
      throw UnimplementedError();

  Future<void> approveDevice(String deviceId, {String? member, DeviceMode? mode}) =>
      throw UnimplementedError();
  Future<void> revokeDevice(String deviceId) => throw UnimplementedError();
  Future<void> updateDevice(String deviceId, Map<String, Object?> patch) => throw UnimplementedError();

  Future<String> addCategory({required String name, String icon = 'calendar'}) =>
      throw UnimplementedError();
  Future<void> updateCategory(String id, Map<String, Object?> patch) => throw UnimplementedError();
  Future<void> deleteCategory(String id) => throw UnimplementedError();

  // ---------------------------------------------------------------- calendar

  /// Occurrences overlapping [start, end) (UTC ms), exceptions applied, sorted by start.
  List<Occurrence> occurrences(int start, int end) => throw UnimplementedError();
  Event? event(String id) => throw UnimplementedError();

  Future<String> addEvent({
    required String title,
    required int start,
    required int end,
    bool allDay = false,
    String? tz,
    String? rrule,
    List<String> assignees = const [],
    String? category,
    String location = '',
    String notes = '',
    List<int> reminders = const [],
    List<Ride> rides = const [],
    bool countdown = false,
    Audience audience = Audience.everyone,
  }) =>
      throw UnimplementedError();

  /// [occurrence] is the occurrence's series start, required for [EditScope.one] and
  /// [EditScope.following] on repeating events. A time change with [EditScope.all] shifts the
  /// whole series by the same delta.
  Future<void> updateEvent(
    String id,
    Map<String, Object?> patch, {
    EditScope scope = EditScope.all,
    int? occurrence,
  }) =>
      throw UnimplementedError();

  Future<void> deleteEvent(String id, {EditScope scope = EditScope.all, int? occurrence}) =>
      throw UnimplementedError();

  /// Sets the driver of a ride leg for one occurrence (null releases it).
  Future<void> claimRide(String eventId, {required int occurrence, required String leg, String? driver}) =>
      throw UnimplementedError();

  // ---------------------------------------------------------------- chores

  List<Chore> get chores => throw UnimplementedError();
  Chore? chore(String id) => throw UnimplementedError();

  /// Chores scheduled on [date] (local), plus earlier one-off chores still not done.
  List<ChoreDay> choresOn(String date) => throw UnimplementedError();

  Future<String> addChore({
    required String title,
    required ChoreOwner owner,
    required ChoreSchedule schedule,
    String icon = 'check',
    String notes = '',
    String? dueTime,
    int points = 0,
    List<ChoreStep> steps = const [],
    List<int> reminders = const [],
    Audience audience = Audience.everyone,
  }) =>
      throw UnimplementedError();

  Future<void> updateChore(String id, Map<String, Object?> patch) => throw UnimplementedError();
  Future<void> deleteChore(String id) => throw UnimplementedError();

  /// Marks the chore done or not done on [date]. Marking done also checks every step, keeping
  /// whoever already checked each one; marking not done clears them.
  Future<void> setChoreDone(String choreId, String date, bool done) => throw UnimplementedError();

  /// Checks or unchecks one step; checking the last one completes the chore, unchecking any
  /// step of a done chore reopens it.
  Future<void> setStep(String choreId, String date, String stepId, bool checked) =>
      throw UnimplementedError();

  /// Hands the chore to [toMember] for [date] only (null gives it to anyone).
  Future<void> swapForDay(String choreId, String date, String? toMember) => throw UnimplementedError();

  // ---------------------------------------------------------------- lists

  /// Lists in display order with their items.
  List<ListView> get lists => throw UnimplementedError();
  ListView? list(String id) => throw UnimplementedError();

  /// Store names used on items, most used first.
  List<String> get stores => throw UnimplementedError();

  Future<String> addList({
    required String title,
    ListKind kind = ListKind.checklist,
    ListLifecycle lifecycle = ListLifecycle.running,
    String? needBy,
    String? event,
    String icon = 'list',
    bool pinned = false,
    Audience audience = Audience.everyone,
  }) =>
      throw UnimplementedError();

  Future<void> updateList(String id, Map<String, Object?> patch) => throw UnimplementedError();
  Future<void> deleteList(String id) => throw UnimplementedError();

  /// Adds an item at the end. On a meal list, [toGroceries] also adds it to the first pinned
  /// shopping list.
  Future<String> addItem(String listId, {required String text, String? qty, String? store, bool toGroceries = false}) =>
      throw UnimplementedError();

  Future<void> updateItem(String id, Map<String, Object?> patch) => throw UnimplementedError();
  Future<void> setItemChecked(String id, bool checked) => throw UnimplementedError();
  Future<void> removeItem(String id) => throw UnimplementedError();

  /// Removes every checked item from a list; returns how many.
  Future<int> clearChecked(String listId) => throw UnimplementedError();

  /// Moves an item between two neighbors (either may be null at the ends).
  Future<void> moveItem(String id, {String? after, String? before}) => throw UnimplementedError();

  // ---------------------------------------------------------------- points

  PointsSummary points() => throw UnimplementedError();

  Future<void> adjustPoints(String memberId, int delta, String reason) => throw UnimplementedError();

  Future<String> addGoal({
    required String title,
    required int target,
    GoalMode mode = GoalMode.target,
    List<String>? members,
    String? start,
    String? end,
    GoalRepeat repeat = GoalRepeat.none,
    String reward = '',
  }) =>
      throw UnimplementedError();

  Future<void> updateGoal(String id, Map<String, Object?> patch) => throw UnimplementedError();
  Future<void> deleteGoal(String id) => throw UnimplementedError();

  Future<String> addReward({required String title, required int cost, String icon = 'gift', bool needsApproval = true}) =>
      throw UnimplementedError();
  Future<void> updateReward(String id, Map<String, Object?> patch) => throw UnimplementedError();

  /// Asks to spend points on a reward for [member] (default: the actor). Rewards that don't
  /// need approval are approved at once.
  Future<String> requestReward(String rewardId, {String? member}) => throw UnimplementedError();
  Future<void> decideRedemption(String id, {required bool approve}) => throw UnimplementedError();

  // ---------------------------------------------------------------- AI and automation connections

  List<Connection> get connections => throw UnimplementedError();

  /// Creates an active token connection and returns the bearer token, which is shown once and
  /// stored only as a hash. Parents only.
  Future<String> addTokenConnection({
    required String label,
    required Set<Scope> scopes,
    String? member,
    int? expires,
  }) =>
      throw UnimplementedError();

  /// Written by a hub when an OAuth client asks for access; a parent then approves or declines it.
  Future<String> requestOAuthConnection({required String label, required String client, required Set<Scope> scopes}) =>
      throw UnimplementedError();

  /// Parents approve a pending connection, optionally narrowing its scopes and choosing whose
  /// permissions it acts with.
  Future<void> approveConnection(String id, {Set<Scope>? scopes, String? member}) =>
      throw UnimplementedError();

  /// Records the hash of an OAuth access token issued for an approved connection (hubs only).
  Future<void> setConnectionToken(String id, String tokenHash, {int? expires}) => throw UnimplementedError();

  Future<void> revokeConnection(String id) => throw UnimplementedError();

  /// The active, unexpired connection whose token hashes to the given bearer token.
  Connection? connectionForToken(String bearerToken) => throw UnimplementedError();

  // ---------------------------------------------------------------- views

  TodayView today({String? date}) => throw UnimplementedError();

  /// The family-columns grid from [startDate] for [days] days.
  WeekGrid week(String startDate, {int days = 7}) => throw UnimplementedError();

  /// Newest first; filtered to what the actor may read.
  List<HistoryEntry> history({String? query, String? member, String? type, int limit = 200}) =>
      throw UnimplementedError();

  List<SearchHit> search(String query, {int limit = 50}) => throw UnimplementedError();
  List<Gap> gaps(int start, int end) => throw UnimplementedError();

  /// Reminders that fire in [from, to) (UTC ms) for [memberId] (null: for anyone).
  List<ReminderDue> remindersDue(int from, int to, {String? memberId}) => throw UnimplementedError();

  // ---------------------------------------------------------------- sync surface

  /// deviceId -> highest contiguous change counter held.
  Map<String, int> get versionVector => throw UnimplementedError();

  /// Changes the holder of [vv] lacks, limited to [spaces] when given, in HLC order.
  List<Change> changesSince(Map<String, int> vv, {Set<String>? spaces}) => throw UnimplementedError();

  /// Stores and applies changes from another device. Duplicates are ignored; invalid changes are
  /// kept but not applied.
  Future<IngestResult> ingest(Iterable<Change> changes) => throw UnimplementedError();

  /// The spaces the given device should hold, per its owner, mode and the family's policy.
  Set<String> spacesForDevice(String deviceId) => throw UnimplementedError();

  /// Space keys used to seal changes on the relay mailbox. Generated at genesis per space.
  Future<List<int>?> spaceKey(String space) => throw UnimplementedError();
  Future<void> setSpaceKey(String space, List<int> key) => throw UnimplementedError();

  /// Every live record as JSON, for export.
  Map<String, Object?> exportJson() => throw UnimplementedError();
}
