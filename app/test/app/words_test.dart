import 'package:den_app/app/words.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reminders read the same for events and chores, except what 0 means', () {
    expect(reminderWords(0), 'At the start');
    expect(reminderWords(0, due: true), "When it's due");
    expect(reminderWords(15), '15 minutes before');
    expect(reminderWords(15, due: true), '15 minutes before');
    expect(reminderWords(60, due: true), '1 hour before');
    expect(reminderWords(90), '1 hour 30 minutes before');
    expect(reminderWords(120), '2 hours before');
    expect(reminderWords(1440), '1 day before');
    expect(reminderWords(2 * 10080), '2 weeks before');
  });
}
