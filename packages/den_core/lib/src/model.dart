import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'hlc.dart';

/// Record type names used in [Change.type]. See ARCHITECTURE.md, "Record types and fields".
abstract final class RecordType {
  static const family = 'family';
  static const member = 'member';
  static const device = 'device';
  static const category = 'category';
  static const event = 'event';
  static const eventException = 'eventException';
  static const chore = 'chore';
  static const completion = 'completion';
  static const adjustment = 'adjustment';
  static const goal = 'goal';
  static const reward = 'reward';
  static const redemption = 'redemption';
  static const list = 'list';
  static const item = 'item';
  static const subscription = 'subscription';
  static const connection = 'connection';
  static const photo = 'photo';
  static const signInTries = 'signInTries';

  static const all = {
    family, member, device, category, event, eventException, chore, completion, adjustment,
    goal, reward, redemption, list, item, subscription, connection, photo, signInTries,
  };
}

/// The pictogram keys records use for icons. The app maps each to a drawing; other clients may
/// store other names, which draw nothing.
abstract final class PictogramKeys {
  static const chores = [
    'check', 'bed', 'tooth', 'broom', 'trash', 'recycle', 'dishes', 'cooking', 'laundry', 'hanger',
    'bath', 'shower', 'toilet', 'spray', 'pet', 'plant', 'leaf', 'book', 'homework', 'backpack',
    'music', 'shoes', 'car', 'mail', 'tools', 'pill', 'science',
  ];
  static const categories = [
    'calendar', 'school', 'sports', 'work', 'health', 'birthday', 'holiday', 'family', 'travel',
    'music', 'party',
  ];
  static const rewards = ['gift', 'film', 'game', 'pizza', 'moon', 'money', 'ticket', 'treat'];

  /// One per [ListKind], by name.
  static const lists = ['shopping', 'checklist', 'packing', 'meal'];
}

/// Space ids. A record lives in exactly one space; devices receive only the spaces they may read.
abstract final class Space {
  static const family = 'f';
  static const parents = 'p';
  static String member(String memberId) => 'm:$memberId';
  static bool isMember(String space) => space.startsWith('m:');
  static String? memberOf(String space) => isMember(space) ? space.substring(2) : null;
}

/// Who can see an item, as offered in the UI. Maps to a [Space].
enum Audience {
  everyone,
  parents,
  justMe;

  String spaceFor(String memberId) => switch (this) {
        Audience.everyone => Space.family,
        Audience.parents => Space.parents,
        Audience.justMe => Space.member(memberId),
      };

  static Audience ofSpace(String space) => space == Space.family
      ? Audience.everyone
      : space == Space.parents
          ? Audience.parents
          : Audience.justMe;
}

enum Role { parent, adult, kid, guest }

enum Tier { preReader, little, big, teen }

/// A person's color: the family pack, in the order new people get them. The app draws each
/// as a validated hex; color is never the only clue, since every person also has a picture or
/// initial and a name. Records written before the pack carry one of ten older names, which
/// [parse] reads as the nearest color.
enum Marker {
  sky,
  grass,
  lavender,
  tangerine,
  aqua,
  coral,
  sunshine,
  bubblegum;

  /// The names earlier versions wrote, read as the nearest family color. `sky` kept its name.
  static const Map<String, Marker> legacyNames = {
    'blue': sky,
    'green': grass,
    'plum': lavender,
    'orange': tangerine,
    'teal': aqua,
    'pink': bubblegum,
    'brown': coral,
    'olive': sunshine,
    'slate': lavender,
  };

  /// Every name a record may carry: today's eight and the older ones.
  static List<String> get allNames => [for (final m in values) m.name, ...legacyNames.keys];

  /// The color [raw] names, older names included; null for anything else.
  static Marker? parse(Object? raw) {
    if (raw is! String) return null;
    for (final m in values) {
      if (m.name == raw) return m;
    }
    return legacyNames[raw];
  }

  /// The color a new person gets: the first in order nobody has yet or, once all eight are
  /// taken, the one the fewest people share.
  static Marker next(Iterable<Marker> taken) {
    final counts = {for (final m in values) m: 0};
    for (final m in taken) {
      counts[m] = counts[m]! + 1;
    }
    var best = values.first;
    for (final m in values) {
      if (counts[m]! < counts[best]!) best = m;
    }
    return best;
  }
}

/// The animals earlier versions offered as a person's look. Members now have a [Picture]; an
/// older member's animal is read as the matching picture.
enum Animal { cat, dog, rabbit, bird, butterfly, fish, horse, cow, bug }

/// What stands for a person: the id of a picture from the app's pack (`fox`, `dinosaur`),
/// [initial] for the first letter of their name, or `photo:<id>` for a small photo kept as a
/// [Photo] record in the family space.
abstract final class Picture {
  static const initial = 'initial';

  /// What a member's picture starts with when it is a photo: `photo:<photo record id>`.
  static const photoPrefix = 'photo:';

  /// The picture that shows the photo record [photoId].
  static String photo(String photoId) => '$photoPrefix$photoId';

  /// The photo record [picture] shows, or null when it isn't a photo.
  static String? photoIdOf(String picture) =>
      picture.startsWith(photoPrefix) && picture.length > photoPrefix.length ? picture.substring(photoPrefix.length) : null;

  /// The pack's pictures by id, in the order the app shows them (its test checks they match), so
  /// surfaces without the artwork (MCP, the assistant) can offer them by name.
  static const pack = [
    'fox', 'bear', 'cat', 'dog', 'bunny', 'owl', 'panda', 'frog', //
    'whale', 'octopus', 'turtle', 'ladybug', 'bee', 'butterfly', 'snail', 'chick',
    'strawberry', 'avocado', 'pizza', 'cupcake', 'watermelon', 'banana', 'icecream', 'pancakes',
    'sunflower', 'cactus', 'mushroom', 'tree', 'rainbow', 'sun', 'moon', 'cloud',
    'soccer', 'basketball', 'rocket', 'guitar', 'palette', 'kite', 'dinosaur', 'robot',
    'house', 'sailboat', 'balloon', 'teacup', 'tent', 'star', 'crown', 'camera',
    'firefighter', 'police', 'doctor', 'spy', 'ninja', 'armyman', 'astronaut', 'pirate',
    'tank', 'jet', 'racecar', 'firetruck', 'helicopter', 'train', 'sheriff', 'revolver',
  ];

  static final RegExp _key = RegExp(r'^[a-z][a-z0-9:_-]{0,63}$');

  static bool valid(Object? raw) => raw is String && _key.hasMatch(raw);

  /// The picture an older member's animal reads as; the pack has no horse or cow.
  static String forAnimal(Animal animal) => switch (animal) {
        Animal.cat => 'cat',
        Animal.dog => 'dog',
        Animal.rabbit => 'bunny',
        Animal.bird => 'owl',
        Animal.butterfly => 'butterfly',
        Animal.fish => 'whale',
        Animal.bug => 'ladybug',
        Animal.horse || Animal.cow => initial,
      };
}

enum DeviceKind { phone, tablet, desktop, browser, hub, display }

enum DeviceMode { personal, shared, hub }

enum Grant { events, chores, lists, points }

enum ListKind { shopping, checklist, packing, meal }

enum ListLifecycle { running, dated, event }

enum GoalMode { target, race }

enum GoalRepeat { none, weekly, monthly }

enum RedemptionStatus { requested, approved, declined }

enum DisplayLayout { today, week, month, lists, photos }

/// What a capture read: the thing someone photographed, shared, said or typed; or, for
/// [assistant], that the in-app assistant made the change while someone talked to it.
enum CaptureKind { photo, screenshot, pdf, email, message, link, voice, typed, assistant }

/// Where a record added by capture came from, written as `_from` on the change that made it:
/// what was read and, when a model read it, which one ("On this phone", "Claude").
@immutable
class CaptureOrigin {
  const CaptureOrigin(this.kind, {this.reader});

  final CaptureKind kind;

  /// Who read it, as people see it in History; null when Den's own reader did.
  final String? reader;

  Map<String, Object?> toJson() => {'kind': kind.name, 'reader': ?reader};

  /// The origin a change recorded, or null when it has none Den understands.
  static CaptureOrigin? parse(Object? raw) {
    if (raw is! Map) return null;
    final kind = _enum(CaptureKind.values, raw['kind']);
    if (kind == null) return null;
    final reader = raw['reader'];
    return CaptureOrigin(kind, reader: reader is String && reader.isNotEmpty ? reader : null);
  }

  @override
  bool operator ==(Object other) => other is CaptureOrigin && other.kind == kind && other.reader == reader;

  @override
  int get hashCode => Object.hash(kind, reader);
}

T? _enum<T extends Enum>(List<T> values, Object? raw) =>
    raw is String ? values.firstWhereOrNull((v) => v.name == raw) : null;

/// The merged state of one record: its fields plus bookkeeping from the change log.
@immutable
class Rec {
  const Rec({
    required this.type,
    required this.id,
    required this.space,
    required this.fields,
    required this.created,
    required this.updated,
    required this.createdBy,
    required this.updatedBy,
    this.fieldTimes = const {},
  });

  final String type;
  final String id;
  final String space;
  final Map<String, Object?> fields;

  /// HLC of the change that set each field's current value. Keys of map fields written one entry
  /// at a time appear as `"<field>.<key>"`.
  final Map<String, Hlc> fieldTimes;

  /// HLC of the first valid change to this record.
  final Hlc created;

  /// HLC of the latest valid change to this record.
  final Hlc updated;

  /// Acting member of the first change (null for open check-off on a display or the hub).
  final String? createdBy;
  final String? updatedBy;

  bool get deleted => fields['_deleted'] == true;

  String str(String name, [String fallback = '']) => fields[name] as String? ?? fallback;
  String? strOrNull(String name) => fields[name] as String?;
  int integer(String name, [int fallback = 0]) => (fields[name] as num?)?.toInt() ?? fallback;
  int? intOrNull(String name) => (fields[name] as num?)?.toInt();
  bool flag(String name, [bool fallback = false]) => fields[name] as bool? ?? fallback;
  List<String> strings(String name) => [...?(fields[name] as List?)?.cast<String>()];
  Map<String, Object?> map(String name) => Map<String, Object?>.from(fields[name] as Map? ?? const {});
  List<Map<String, Object?>> maps(String name) =>
      [...?(fields[name] as List?)?.map((e) => Map<String, Object?>.from(e as Map))];
}

/// Base for typed views over a [Rec].
abstract class RecordView {
  const RecordView(this.rec);
  final Rec rec;
  String get id => rec.id;
  String get space => rec.space;
  Audience get audience => Audience.ofSpace(rec.space);
}

class Family extends RecordView {
  const Family(super.rec);
  String get name => rec.str('name');
  String get timezone => rec.str('timezone', 'UTC');
  int get weekStart => rec.integer('weekStart');
  String get founderDevice => rec.str('founderDevice');
  bool get captureNeedsReview => rec.str('capture', 'direct') == 'review';
  bool get pointsEnabled => rec.flag('pointsEnabled', true);

  /// Whether parents can read this member's "Just me" items. Defaults to true.
  bool parentsSeePrivate(String memberId) =>
      (rec.map('oversight')[memberId] as Map?)?['parentsSeePrivate'] as bool? ?? true;

  /// One of a person's own settings ([OversightSetting]), or null when no parent has set it.
  /// Each is an entry of its own, `oversight.<memberId>.<setting>`, so two parents changing
  /// different settings merge, and the privacy entry keeps the shape older versions read.
  bool? setting(String memberId, String setting) {
    final v = rec.map('oversight')['$memberId.$setting'];
    return v is bool ? v : null;
  }

  /// Whether [memberId]'s reward requests wait for a parent's OK. Defaults to true; a parent
  /// can turn it off for one kid, and then a reward they can afford is theirs at once.
  bool rewardsNeedOk(String memberId) => setting(memberId, OversightSetting.rewardsNeedOk) ?? true;

  /// Whether [member] may change their own picture, a photo too. Parents, grown-ups and
  /// sitters always may; a kid when a parent allows it, which a teen starts out with and a
  /// younger kid doesn't.
  bool ownsPicture(Member member) {
    if (!member.isKid) return true;
    return setting(member.id, OversightSetting.ownPicture) ?? member.tier == Tier.teen;
  }

  /// Who may use the in-app assistant; off until a parent turns it on.
  AssistantPolicy get assistant => AssistantPolicy.parse(rec.map('assistant'));
}

/// The per-person settings a parent keeps in `family.oversight` besides privacy, each written
/// as its own entry `oversight.<memberId>.<setting>` holding a bool.
abstract final class OversightSetting {
  /// Whether a kid's reward requests wait for a parent (default true).
  static const rewardsNeedOk = 'rewardsNeedOk';

  /// Whether a kid may change their own picture (default: teens yes, younger kids no).
  static const ownPicture = 'ownPicture';

  static const all = {rewardsNeedOk, ownPicture};
}

/// The family's rules for the in-app assistant (`family.assistant`), set by a parent on their
/// own device. Off until a parent turns it on; then parents may use it, and anyone else only
/// when a parent switched it on for them, never a little kid or a pre-reader. The hub's model
/// proxy holds kids to [kidDailyLimit] requests a day and the family to [budgetCents] a month.
@immutable
class AssistantPolicy {
  const AssistantPolicy({
    this.enabled = false,
    this.members = const {},
    this.kidDailyLimit = defaultKidDailyLimit,
    this.budgetCents = defaultBudgetCents,
  });

  /// Requests a day for a kid, unless a parent sets another number.
  static const int defaultKidDailyLimit = 20;

  /// A month's budget in US cents ($5), unless a parent sets another.
  static const int defaultBudgetCents = 500;

  /// The policy stored as [raw]; anything missing or malformed is its default.
  static AssistantPolicy parse(Map<String, Object?> raw) {
    final members = raw['members'];
    final limit = raw['kidDailyLimit'];
    final budget = raw['budgetCents'];
    return AssistantPolicy(
      enabled: raw['enabled'] == true,
      members: {if (members is List) ...members.whereType<String>()},
      kidDailyLimit: limit is int ? limit : defaultKidDailyLimit,
      budgetCents: budget is int ? budget : defaultBudgetCents,
    );
  }

  /// Whether a parent turned the assistant on.
  final bool enabled;

  /// Who besides parents may use it (member ids).
  final Set<String> members;

  /// Requests a kid may make in a day.
  final int kidDailyLimit;

  /// The family's monthly budget, in US cents.
  final int budgetCents;

  /// Whether [m] may use the assistant.
  bool allows(Member m) {
    if (!enabled) return false;
    if (m.isParent) return true;
    if (m.tier == Tier.preReader || m.tier == Tier.little) return false;
    return members.contains(m.id);
  }

  /// As `family.assistant` stores it.
  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'members': [...members]..sort(),
        'kidDailyLimit': kidDailyLimit,
        'budgetCents': budgetCents,
      };

  @override
  bool operator ==(Object other) =>
      other is AssistantPolicy &&
      other.enabled == enabled &&
      other.kidDailyLimit == kidDailyLimit &&
      other.budgetCents == budgetCents &&
      const SetEquality<String>().equals(other.members, members);

  @override
  int get hashCode => Object.hash(enabled, kidDailyLimit, budgetCents, Object.hashAllUnordered(members));
}

/// How someone signs in on shared screens (`member.signIn`): the kind, and for a PIN or picture
/// pattern its salted hash and how that was stretched (secrets.dart).
class SignIn {
  const SignIn(this.kind, this.salt, this.hash, {this.digits = 4, this.kdf, this.memoryKiB, this.iterations, this.parallelism});

  factory SignIn.fromMap(Map<String, Object?> raw) => SignIn(
        raw['kind'] as String? ?? 'none',
        raw['salt'] as String?,
        raw['hash'] as String?,
        digits: (raw['digits'] as num?)?.toInt() ?? 4,
        kdf: raw['kdf'] as String?,
        memoryKiB: (raw['memoryKiB'] as num?)?.toInt(),
        iterations: (raw['iterations'] as num?)?.toInt(),
        parallelism: (raw['parallelism'] as num?)?.toInt(),
      );

  final String kind; // pin | pattern | none
  final String? salt;
  final String? hash;

  /// How many digits a PIN has: 4, or 6.
  final int digits;

  /// How the hash was stretched: `argon2id-v1` with [memoryKiB], [iterations] and [parallelism],
  /// or null for PBKDF2 (20,000 rounds), which sign-ins set before Argon2id still use.
  final String? kdf;
  final int? memoryKiB;
  final int? iterations;
  final int? parallelism;

  /// Whether it is a PIN or pattern stretched the old, faster way: it still works, and is
  /// stretched the new way when it is next set.
  bool get stretchedOld => (kind == 'pin' || kind == 'pattern') && hash != null && kdf == null;
}

class Member extends RecordView {
  const Member(super.rec);
  String get name => rec.str('name');
  Role get role => _enum(Role.values, rec.fields['role']) ?? Role.kid;
  Tier? get tier => _enum(Tier.values, rec.fields['tier']);
  Marker get marker => Marker.parse(rec.fields['marker']) ?? Marker.lavender;
  Animal get animal => _enum(Animal.values, rec.fields['animal']) ?? Animal.cat;

  /// Their [Picture]: the one chosen for them or, for a member written before pictures, the
  /// picture their animal reads as.
  String get picture {
    final raw = rec.fields['picture'];
    if (Picture.valid(raw)) return raw as String;
    final animal = _enum(Animal.values, rec.fields['animal']);
    return animal == null ? Picture.initial : Picture.forAnimal(animal);
  }

  String? get birthday => rec.strOrNull('birthday');

  /// For a sitter ([Role.guest]): the last local date (in the family's time zone) they have
  /// access, or null for no end.
  String? get until => rec.strOrNull('until');

  /// Whether a sitter's access is over on [today] (a local date): today is past [until].
  bool accessEndedOn(String today) {
    final last = until;
    return role == Role.guest && last != null && today.compareTo(last) > 0;
  }

  /// The photo record their picture shows, or null.
  String? get photo => Picture.photoIdOf(picture);

  Set<Grant> get grants =>
      rec.strings('grants').map((g) => _enum(Grant.values, g)).whereType<Grant>().toSet();
  SignIn get signIn => SignIn.fromMap(rec.map('signIn'));

  int get order => rec.integer('order');
  bool get isParent => role == Role.parent;
  bool get isKid => role == Role.kid;
}

/// A shared screen saying that someone got a person's PIN or picture pattern wrong [tries] times
/// in a row there, so the parents hear of it on their own phones. Written by the screen, for
/// nobody, and never changed.
class SignInTries extends RecordView {
  const SignInTries(super.rec);

  /// The shared screen.
  String get device => rec.str('device');

  /// Whose PIN or pattern.
  String get member => rec.str('member');
  int get tries => rec.integer('tries');

  /// When the screen said so (UTC milliseconds).
  int get at => rec.created.millis;
}

class Device extends RecordView {
  const Device(super.rec);
  String get name => rec.str('name');
  DeviceKind get kind => _enum(DeviceKind.values, rec.fields['kind']) ?? DeviceKind.phone;
  String get pubkey => rec.str('pubkey');
  String get xpub => rec.str('xpub');
  String? get member => rec.strOrNull('member');
  DeviceMode get mode => _enum(DeviceMode.values, rec.fields['mode']) ?? DeviceMode.personal;
  bool get approved => rec.flag('approved');
  String? get approvedBy => rec.strOrNull('approvedBy');
  bool get revoked => rec.flag('revoked');

  /// The last of this device's changes the device that revoked it held; see ARCHITECTURE.md,
  /// "Genesis and trust".
  int? get revokedAfter => rec.intOrNull('revokedAfter');
  DisplayLayout get layout =>
      _enum(DisplayLayout.values, rec.map('display')['layout']) ?? DisplayLayout.today;
  bool get openCheckoff => rec.map('display')['openCheckoff'] as bool? ?? false;
  bool get isShared => mode != DeviceMode.personal;
}

class EventCategory extends RecordView {
  const EventCategory(super.rec);
  String get name => rec.str('name');
  String get icon => rec.str('icon', 'calendar');
}

class EventSource {
  const EventSource(this.kind, this.ref, this.label);
  final String kind; // manual | ics | device
  final String? ref;
  final String? label;
  bool get readOnly => kind != 'manual';
}

class Ride {
  const Ride(this.leg, this.driver);
  final String leg; // to | from
  final String? driver;
}

class Event extends RecordView {
  const Event(super.rec);
  String get title => rec.str('title');
  String get notes => rec.str('notes');
  String get location => rec.str('location');
  String? get category => rec.strOrNull('category');
  int get start => rec.integer('start');
  int get end => rec.integer('end');
  bool get allDay => rec.flag('allDay');
  String get tz => rec.str('tz', 'UTC');
  String? get rrule => rec.strOrNull('rrule');
  List<String> get assignees => rec.strings('assignees');
  List<int> get reminders => [...?(rec.fields['reminders'] as List?)?.map((e) => (e as num).toInt())];
  EventSource get source {
    final raw = rec.map('source');
    return EventSource(raw['kind'] as String? ?? 'manual', raw['ref'] as String?, raw['label'] as String?);
  }

  List<Ride> get rides =>
      rec.maps('rides').map((r) => Ride(r['leg'] as String? ?? 'to', r['driver'] as String?)).toList();
  bool get countdown => rec.flag('countdown');
}

class EventException extends RecordView {
  const EventException(super.rec);
  String get event => rec.str('event');
  int get occurrence => rec.integer('occurrence');
  bool get cancelled => rec.flag('cancelled');
  Map<String, Object?> get patch => rec.map('patch');
}

/// Who a chore belongs to.
sealed class ChoreOwner {
  const ChoreOwner();
  static ChoreOwner parse(Map<String, Object?> raw) => switch (raw['kind']) {
        'member' => OwnerMember(raw['id']! as String),
        'rotation' => OwnerRotation(
            [...(raw['ids']! as List).cast<String>()],
            raw['every'] as String? ?? 'week',
            raw['anchor']! as String,
          ),
        _ => const OwnerAnyone(),
      };
  Map<String, Object?> toJson();
}

class OwnerMember extends ChoreOwner {
  const OwnerMember(this.id);
  final String id;
  @override
  Map<String, Object?> toJson() => {'kind': 'member', 'id': id};
}

class OwnerAnyone extends ChoreOwner {
  const OwnerAnyone();
  @override
  Map<String, Object?> toJson() => {'kind': 'anyone'};
}

class OwnerRotation extends ChoreOwner {
  const OwnerRotation(this.ids, this.every, this.anchor);
  final List<String> ids;
  final String every; // day | week
  final String anchor; // local date the rotation starts on ids[0]
  @override
  Map<String, Object?> toJson() => {'kind': 'rotation', 'ids': ids, 'every': every, 'anchor': anchor};
}

/// When a chore happens: a recurrence rule from a start date, or once on a date.
class ChoreSchedule {
  const ChoreSchedule.repeating(String this.rrule, String this.start) : once = null;
  const ChoreSchedule.once(String this.once)
      : rrule = null,
        start = null;
  final String? rrule;
  final String? start;
  final String? once;

  static ChoreSchedule parse(Map<String, Object?> raw) => raw['once'] != null
      ? ChoreSchedule.once(raw['once']! as String)
      : ChoreSchedule.repeating(raw['rrule'] as String? ?? 'FREQ=DAILY', raw['start'] as String? ?? '1970-01-01');

  Map<String, Object?> toJson() => once != null ? {'once': once} : {'rrule': rrule, 'start': start};
}

class ChoreStep {
  const ChoreStep({required this.id, required this.text, this.owner, this.points = 0, this.icon});
  final String id;
  final String text;
  final String? owner;
  final int points;

  /// A chore pictogram key ([PictogramKeys.chores]) shown to people who can't read yet.
  final String? icon;

  static ChoreStep parse(Map<String, Object?> raw) => ChoreStep(
        id: raw['id']! as String,
        text: raw['text'] as String? ?? '',
        owner: raw['owner'] as String?,
        points: (raw['points'] as num?)?.toInt() ?? 0,
        icon: raw['icon'] as String?,
      );

  Map<String, Object?> toJson() =>
      {'id': id, 'text': text, 'owner': owner, 'points': points, if (icon != null) 'icon': icon};
}

class Chore extends RecordView {
  const Chore(super.rec);
  String get title => rec.str('title');
  String get notes => rec.str('notes');
  String get icon => rec.str('icon', 'check');
  ChoreOwner get owner => ChoreOwner.parse(rec.map('owner'));
  ChoreSchedule get schedule => ChoreSchedule.parse(rec.map('schedule'));
  String? get dueTime => rec.strOrNull('dueTime');
  int get points => rec.integer('points');
  List<ChoreStep> get steps => rec.maps('steps').map(ChoreStep.parse).toList();
  List<int> get reminders => [...?(rec.fields['reminders'] as List?)?.map((e) => (e as num).toInt())];
  bool get active => rec.flag('active', true);
}

class Completion extends RecordView {
  const Completion(super.rec);
  String get chore => rec.str('chore');
  String get date => rec.str('date');
  bool get done => rec.flag('done');
  String? get doneBy => rec.strOrNull('doneBy');

  /// One-day owner override (a swap).
  String? get owner => rec.strOrNull('owner');

  /// stepId -> member who checked it; unchecked steps are absent or null.
  Map<String, String?> get steps =>
      rec.map('steps').map((k, v) => MapEntry(k, v as String?));

  /// What the chore was worth when it was done, or null for a completion from before Den kept
  /// that (it is worth what the chore is worth now).
  int? get points => rec.intOrNull('points');

  /// stepId -> what the step was worth when it was checked; steps absent here are worth what
  /// they are worth now.
  Map<String, int> get stepPoints => {
        for (final e in rec.map('stepPoints').entries)
          if (e.value is num) e.key: (e.value as num).toInt(),
      };

  static String idFor(String choreId, String date) => '$choreId@$date';
}

class Adjustment extends RecordView {
  const Adjustment(super.rec);
  String get member => rec.str('member');
  int get delta => rec.integer('delta');
  String get reason => rec.str('reason');
  String? get by => rec.strOrNull('by');
}

class Goal extends RecordView {
  const Goal(super.rec);
  String get title => rec.str('title');
  GoalMode get mode => _enum(GoalMode.values, rec.fields['mode']) ?? GoalMode.target;
  int get target => rec.integer('target', 1);
  List<String>? get members => rec.fields['members'] == null ? null : rec.strings('members');
  String get start => rec.str('start');
  String? get end => rec.strOrNull('end');
  GoalRepeat get repeat => _enum(GoalRepeat.values, rec.fields['repeat']) ?? GoalRepeat.none;
  String get reward => rec.str('reward');
}

class Reward extends RecordView {
  const Reward(super.rec);
  String get title => rec.str('title');
  int get cost => rec.integer('cost');
  String get icon => rec.str('icon', 'gift');
  bool get needsApproval => rec.flag('needsApproval', true);
  bool get active => rec.flag('active', true);
}

class Redemption extends RecordView {
  const Redemption(super.rec);
  String get reward => rec.str('reward');
  String get member => rec.str('member');
  int get cost => rec.integer('cost');
  RedemptionStatus get status =>
      _enum(RedemptionStatus.values, rec.fields['status']) ?? RedemptionStatus.requested;
  String? get decidedBy => rec.strOrNull('decidedBy');
}

class DenList extends RecordView {
  const DenList(super.rec);
  String get title => rec.str('title');
  String get icon => rec.str('icon', kind.name);
  ListKind get kind => _enum(ListKind.values, rec.fields['kind']) ?? ListKind.checklist;
  ListLifecycle get lifecycle =>
      _enum(ListLifecycle.values, rec.fields['lifecycle']) ?? ListLifecycle.running;
  String? get needBy => rec.strOrNull('needBy');
  String? get event => rec.strOrNull('event');
  bool get pinned => rec.flag('pinned');
  String get order => rec.str('order', 'm');
}

class Item extends RecordView {
  const Item(super.rec);
  String get list => rec.str('list');
  String get text => rec.str('text');
  String? get qty => rec.strOrNull('qty');
  String? get store => rec.strOrNull('store');
  bool get checked => rec.flag('checked');
  String? get checkedBy => rec.strOrNull('checkedBy');
  String get order => rec.str('order', 'm');
  bool get toGroceries => rec.flag('toGroceries');
}

enum ConnectionKind { token, oauth }

enum ConnectionStatus { pending, active, revoked }

/// Scopes for AI and automation connections. `read` covers every read.
enum Scope { read, calendar, chores, lists, points, admin }

/// An AI or automation client allowed to use the hub's API or MCP server. Lives in space `p`.
class Connection extends RecordView {
  const Connection(super.rec);
  String get label => rec.str('label');
  ConnectionKind get kind => _enum(ConnectionKind.values, rec.fields['kind']) ?? ConnectionKind.token;
  Set<Scope> get scopes =>
      rec.strings('scopes').map((s) => _enum(Scope.values, s)).whereType<Scope>().toSet();

  /// Whose permissions the connection acts with; null means a parent-level automation.
  String? get member => rec.strOrNull('member');

  /// SHA-256 hex of the bearer token (token connections, and OAuth access tokens once issued).
  String? get tokenHash => rec.strOrNull('tokenHash');
  String? get client => rec.strOrNull('client');
  ConnectionStatus get status =>
      _enum(ConnectionStatus.values, rec.fields['status']) ?? ConnectionStatus.pending;
  int? get expires => rec.intOrNull('expires');
}

class Subscription extends RecordView {
  const Subscription(super.rec);
  String get url => rec.str('url');
  String get label => rec.str('label');
  String? get category => rec.strOrNull('category');
  String? get assignee => rec.strOrNull('assignee');
  String get targetSpace => rec.str('space', Space.family);
  List<String> get include => rec.strings('include');
  List<String> get exclude => rec.strings('exclude');
  bool get skipAllDay => rec.flag('skipAllDay');
  String get status => rec.str('status');
}

/// A person's small photo (`photo` records, space `f`): a 256 px square JPEG or WebP of at most
/// [maxBytes], made small on the device that took it. A photo never changes; a new picture is a
/// new record, and the member's `picture` names the one in use (`photo:<id>`).
class Photo extends RecordView {
  const Photo(super.rec);

  /// The photo's side, in pixels.
  static const int side = 256;

  /// The most a photo may weigh, encoded.
  static const int maxBytes = 40 * 1024;

  static const String jpeg = 'image/jpeg';
  static const String webp = 'image/webp';

  /// Whose photo it is.
  String get member => rec.str('member');

  /// `image/jpeg` or `image/webp`.
  String get mime => rec.str('mime', jpeg);

  /// The encoded image, base64 (standard alphabet, padded).
  String get data => rec.str('data');
}
