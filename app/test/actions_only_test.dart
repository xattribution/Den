/// Fails when app code changes the family anywhere but through den_actions, so that every change
/// the app makes is also an action the hub's REST API, MCP and the assistant offer (den_actions'
/// coverage test checks that every engine write has an action or a written reason not to).
///
/// The app always calls the engine `den` (`den.`, `_den.`, `app.den.`, `context.den.`), so a
/// direct write reads `den.<write method>(`. The few writes no action offers on purpose (this
/// device's own setup, who is acting on a shared screen, and a parent's trust decisions) are
/// allowed only in a feature's `state/` or in `platform/`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every public `Future<...> name(` method of `Den`, read from its source the way den_actions'
/// coverage test reads them, plus [Den.actAs].
Set<String> engineWrites() {
  final source = File('../packages/den_core/lib/src/den.dart').readAsStringSync();
  return {
    for (final m in RegExp(r'^  (?:static )?Future<[^\s(]*> ([a-zA-Z]\w*)(?:<\w+>)?\(', multiLine: true).allMatches(source))
      m.group(1)!,
    'actAs',
  }..removeAll({'open', 'close'});
}

/// Writes about this device itself, which change nothing about the family.
const Map<String, String> deviceLocal = {
  'setThisDeviceMode': 'What this device is for, set on it by a parent',
  'createFamily': 'A family is founded once, on the founding parent\'s own device',
  'requestJoin': 'A device asks to join from itself',
  'leaveFamily': 'Forgetting the family is done on the device that leaves',
  'actAs': 'Who is acting on a shared screen',
  'verifySignIn': 'Checking a PIN or pattern on a shared screen',
  'requestRecovery': 'A new phone lets itself in with a parent\'s recovery words or the hub\'s proof',
};

/// Trust decisions: only a parent on their own device makes them, never anything acting
/// through the hub, so no action offers them.
const Set<String> trust = {
  'removeMember',
  'setSignIn',
  'approveDevice',
  'revokeDevice',
  'updateDevice',
  'addTokenConnection',
  'approveConnection',
  'revokeConnection',
  'endExpiredAccess',
  'endAccessNow',
  'setRecoveryKey',
  'setServerRecoveryKey',
  // "That wasn't us": removes a phone recovery let in and turns off what let it in.
  'disownRecovery',
};

/// Writes in one file each, with why.
const Map<String, Set<String>> perFile = {
  // Someone's role and permissions, and whether parents see a kid's private items: trust
  // decisions made through methods whose other fields do have actions.
  'lib/features/family/state/trust_actions.dart': {'updateMember', 'updateFamily'},
  // A photo, made small on this device: no action offers it, so an AI can't add one.
  'lib/features/family/state/picture_actions.dart': {'setPhoto'},
  // The app's actions layer itself: what a reviewed draft changed, and taking it back.
  'lib/app/actions.dart': {'recording', 'undo'},
  // Mirroring this phone's own calendars is a sync, not something a person does.
  'lib/platform/calendars/phone_calendars.dart': {'addEvent', 'updateEvent', 'deleteEvent'},
};

void main() {
  final writes = engineWrites();
  final call = RegExp(r'(?:^|[^\w])_?den\.(\w+)\(');
  final stateLayer = RegExp(r'^lib/(platform/|features/[^/]+/state/)');

  List<File> appFiles() => [
        for (final f in Directory('lib').listSync(recursive: true))
          if (f is File && f.path.endsWith('.dart')) f,
      ];

  String relative(File f) => f.path.replaceAll(r'\', '/');

  test('the engine has the write methods this test expects to find', () {
    expect(writes, containsAll(['addEvent', 'setChoreDone', 'updateMember', 'approveDevice', 'actAs']));
    expect(writes.length, greaterThan(50));
  });

  test('app code writes to the engine only through den_actions, and the allowed few from state/', () {
    final wrong = <String>[];
    for (final file in appFiles()) {
      final rel = relative(file);
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first;
        for (final m in call.allMatches(code)) {
          final name = m.group(1)!;
          if (!writes.contains(name)) continue;
          final allowed = (perFile[rel]?.contains(name) ?? false) ||
              (stateLayer.hasMatch(rel) && (deviceLocal.containsKey(name) || trust.contains(name)));
          if (!allowed) wrong.add('$rel:${i + 1}: den.$name');
        }
      }
    }
    expect(
      wrong,
      isEmpty,
      reason: 'Make the change through the feature\'s actions in state/ (an action from den_actions); a write no '
          'action offers on purpose goes in state/ and in this test\'s lists, with why.',
    );
  });

  test('what Add read is written only by its controller, through a recorded receipt', () {
    final wrong = [
      for (final file in appFiles())
        if (!relative(file).startsWith('lib/features/add/state/') && file.readAsStringSync().contains('writeDraft('))
          relative(file),
    ];
    expect(wrong, isEmpty);
  });
}
