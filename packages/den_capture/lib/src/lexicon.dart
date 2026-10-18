/// Words that point at a chore pictogram or an event category, shared by resolution (to pick an
/// icon for a chore a model found) and Den's own reader.
library;

const Map<String, List<String>> _choreIcons = {
  'trash': ['trash', 'garbage', 'bins', 'bin out'],
  'recycle': ['recycl'],
  'dishes': ['dish', 'dishwasher', 'clear the table', 'set the table'],
  'laundry': ['laundry', 'wash clothes', 'fold'],
  'hanger': ['hang up', 'put away clothes'],
  'bed': ['bed'],
  'tooth': ['teeth', 'tooth', 'floss'],
  'broom': ['sweep', 'vacuum', 'mop', 'tidy', 'clean room', 'clean your room', 'clean up'],
  'cooking': ['cook', 'dinner', 'lunch', 'breakfast', 'meal prep'],
  'pet': ['feed the', 'cat', 'dog', 'pet', 'fish', 'litter', 'walk the'],
  'plant': ['water the', 'plants', 'garden'],
  'leaf': ['leaves', 'rake', 'mow', 'lawn', 'yard', 'weed'],
  'book': ['read', 'book', 'library'],
  'homework': ['homework', 'study', 'worksheet', 'spelling'],
  'backpack': ['backpack', 'pack lunch', 'school bag'],
  'music': ['piano', 'violin', 'guitar', 'practice', 'instrument'],
  'shoes': ['shoes', 'boots'],
  'car': ['car', 'wash the car'],
  'mail': ['mail', 'package'],
  'tools': ['fix', 'repair', 'tools'],
  'pill': ['medicine', 'pill', 'vitamin'],
  'bath': ['bath'],
  'shower': ['shower'],
  'toilet': ['toilet', 'bathroom'],
  'spray': ['wipe', 'counter', 'clean'],
};

// In order: the first kind with a matching word wins ("No school" is a holiday, "Piano
// practice" is music).
const Map<String, List<String>> _eventKinds = {
  'holiday': ['holiday', 'thanksgiving', 'christmas', 'hanukkah', 'no school', 'break', 'vacation day', 'easter', 'halloween'],
  'birthday': ['birthday', 'bday'],
  'health': ['doctor', 'dentist', 'checkup', 'check-up', 'appointment', 'vaccine', 'orthodontist', 'pediatrician', 'therapy', 'eye exam'],
  'music': ['recital', 'concert', 'piano', 'violin', 'guitar', 'band', 'choir', 'orchestra'],
  'school': [
    'school', 'class', 'teacher', 'pta', 'pto', 'conference', 'picture day', 'book fair', 'field trip',
    'dismissal', 'science night', 'open house', 'report card', 'kindergarten', 'tutor',
  ],
  'sports': [
    'soccer', 'practice', 'game', 'swim', 'basketball', 'baseball', 'softball', 'football', 'hockey',
    'tennis', 'dance', 'karate', 'gymnastics', 'clinic', 'tournament', 'match', 'meet', 'lacrosse',
    'volleyball', 'track', 'gym',
  ],
  'party': ['party', 'celebration', 'sleepover'],
  'travel': ['trip', 'flight', 'vacation', 'travel', 'camp'],
  'family': ['family', 'grandma', 'grandpa', 'reunion'],
  'work': ['work', 'meeting', 'shift', 'office'],
};

String _lower(String text) => ' ${text.toLowerCase()} ';

/// The chore pictogram key for a chore's title, or `check`.
String choreIcon(String title) {
  final t = _lower(title);
  for (final e in _choreIcons.entries) {
    if (e.value.any(t.contains)) return e.key;
  }
  return 'check';
}

/// The category key an event's title suggests, or null.
String? eventKind(String title) {
  final t = _lower(title);
  for (final e in _eventKinds.entries) {
    if (e.value.any((w) => RegExp('\\b${RegExp.escape(w)}').hasMatch(t))) return e.key;
  }
  return null;
}

/// Whether [text] reads like a household task rather than something on the calendar.
bool looksLikeChore(String text) {
  final t = _lower(text);
  if (RegExp(r'\bchores?\b').hasMatch(t)) return true;
  const phrases = [
    'take out the', 'takes out the', 'trash', 'garbage', 'recycling', 'dishes', 'dishwasher', 'laundry',
    'make bed', 'make the bed', 'makes the bed', 'make his bed', 'make her bed', 'make your bed', 'feed the',
    'feeds the', 'walk the dog', 'walks the dog', 'vacuum', 'sweep', 'mow', 'water the plants', 'clean room',
    'clean his room', 'clean her room', 'clean your room', 'set the table', 'clear the table', 'empty the',
    'fold the', 'litter box', 'rake', 'unload',
  ];
  return phrases.any(t.contains);
}

/// Third-person verbs said of a chore's owner, and how a chore title says them: "Leo takes out
/// the trash" becomes "Take out the trash".
const Map<String, String> choreVerbs = {
  'takes': 'take', 'feeds': 'feed', 'walks': 'walk', 'empties': 'empty', 'does': 'do', 'makes': 'make',
  'cleans': 'clean', 'waters': 'water', 'sets': 'set', 'clears': 'clear', 'unloads': 'unload',
  'loads': 'load', 'vacuums': 'vacuum', 'sweeps': 'sweep', 'mows': 'mow', 'folds': 'fold', 'washes': 'wash',
  'brings': 'bring', 'puts': 'put', 'rakes': 'rake', 'wipes': 'wipe', 'scoops': 'scoop', 'practices': 'practice',
  'reads': 'read', 'packs': 'pack', 'tidies': 'tidy', 'mops': 'mop', 'dusts': 'dust', 'helps': 'help',
};
