import 'package:den_core/den_core.dart';

/// What adding a kitchen screen with its code says, on the screen and on the parent's phone.
abstract final class KitchenScreenWords {
  static const screenTitle = 'Kitchen screen';

  /// On the screen, above its code.
  static const howToAdd = "On a parent's phone, open Den and go to Settings, Kitchen screen, Add a screen. Type this code:";

  static const waiting = 'Waiting for a parent to type it';
  static const joining = 'A parent added this screen. Joining the family';
  static const approved = 'Opening the family';
  static const ranOut = 'This code ran out.';
  static const scanInstead = "Or scan it with a parent's phone";

  /// On a parent's phone, before a code is typed: where the code comes from.
  static const whereTheCodeIs =
      "On the tablet or screen, open your family's Den address and choose Set up as a kitchen screen. It shows the code.";

  /// "Works for 9 more minutes", for the time [left].
  static String timeLeft(Duration left) {
    final minutes = (left.inSeconds / 60).ceil();
    if (minutes <= 1) return 'Works for less than a minute more';
    return 'Works for $minutes more minutes';
  }

  /// A code read out character by character for a screen reader: "K 7 Q M, 3 R X A".
  static String spelled(String code) {
    final chars = code.split('');
    if (chars.length != 8) return chars.join(' ');
    return '${chars.sublist(0, 4).join(' ')}, ${chars.sublist(4).join(' ')}';
  }

  /// The name a screen suggests for itself: "Kitchen iPad", "Kitchen tablet", "Kitchen screen".
  static String suggestedName(DeviceKind kind, {bool ipad = false}) => switch (kind) {
        DeviceKind.tablet => ipad ? 'Kitchen iPad' : 'Kitchen tablet',
        _ => 'Kitchen screen',
      };

  /// "Add Kitchen iPad as a kitchen screen?"
  static String confirm(String name) => 'Add ${name.trim().isEmpty ? 'this screen' : name.trim()} as a kitchen screen?';

  static const whatItDoes = "It shows the family's week and today's chores to everyone at home. It's nobody's own device.";

  /// After it was added.
  static String added(String name) => '$name is a kitchen screen now';
  static const afterAdded = 'It shows the family in a moment. Choose what it shows under Kitchen screen.';
}
