@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_core/src/snapshot.dart';
import 'package:den_core/storage_io.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('den_storage_'));
  tearDown(() async => dir.delete(recursive: true));

  File log() => File('${dir.path}${Platform.pathSeparator}changes.jsonl');

  test('a fresh directory has no changes and no metadata', () async {
    final storage = FileStorage('${dir.path}${Platform.pathSeparator}new');
    expect(await storage.loadChanges(), isEmpty);
    expect(await storage.loadMeta(), isNull);
  });

  test('changes and metadata round-trip, and a Den reopens to the same state', () async {
    final clock = TestClock.at(DateTime.utc(2026, 2, 1, 15));
    final keys = await DeviceKeys.generate();
    final first = await openDen(clock, storage: FileStorage(dir.path), keys: keys);
    await first.createFamily(
      familyName: 'Park family',
      timezone: 'America/New_York',
      yourName: 'Jin',
      marker: Marker.sky,
      animal: Animal.bird,
      deviceName: 'Jin\'s phone',
      deviceKind: DeviceKind.phone,
    );
    final list = await first.addList(title: 'Groceries', kind: ListKind.shopping);
    await first.addItem(list, text: 'Kimchi');
    final export = jsonEncode(first.exportJson());

    final reopened = await openDen(clock, storage: FileStorage(dir.path), keys: keys);
    expect(jsonEncode(reopened.exportJson()), export);
    expect(reopened.versionVector, first.versionVector);
    expect(await reopened.spaceKey(Space.family), await first.spaceKey(Space.family));
    expect(dir.listSync().map((e) => e.uri.pathSegments.last), unorderedEquals(['changes.jsonl', 'meta.json']));
    await reopened.addItem(list, text: 'Rice');
    expect(log().readAsLinesSync(), hasLength(6));
  });

  test('a last line cut short by a crash is dropped and trimmed', () async {
    final clock = TestClock.at(DateTime.utc(2026, 2, 1, 15));
    final keys = await DeviceKeys.generate();
    final den = await openDen(clock, storage: FileStorage(dir.path), keys: keys);
    await den.createFamily(
      familyName: 'Park family',
      timezone: 'UTC',
      yourName: 'Jin',
      marker: Marker.sky,
      animal: Animal.bird,
      deviceName: 'Phone',
      deviceKind: DeviceKind.phone,
    );
    await den.addCategory(name: 'Sports');
    final good = log().readAsStringSync();
    final lastLine = good.trimRight().split('\n').last;
    log().writeAsStringSync('$good${lastLine.substring(0, lastLine.length ~/ 2)}');

    final storage = FileStorage(dir.path);
    final loaded = await storage.loadChanges();
    expect(loaded, hasLength(4));
    expect(log().readAsStringSync(), good, reason: 'the partial line is trimmed so later appends start clean');
    await storage.appendChanges([loaded.last]);
    expect(await storage.loadChanges(), hasLength(5));

    final reopened = await openDen(clock, storage: FileStorage(dir.path), keys: keys);
    expect(reopened.categories.single.name, 'Sports');
    await reopened.addCategory(name: 'School');
    expect(reopened.categories.map((c) => c.name), ['School', 'Sports']);
  });

  test('a complete last line without its newline is kept', () async {
    final clock = TestClock.at(DateTime.utc(2026, 2, 1, 15));
    final den = await openDen(clock, storage: FileStorage(dir.path));
    await den.createFamily(
      familyName: 'Park family',
      timezone: 'UTC',
      yourName: 'Jin',
      marker: Marker.sky,
      animal: Animal.bird,
      deviceName: 'Phone',
      deviceKind: DeviceKind.phone,
    );
    final text = log().readAsStringSync();
    log().writeAsStringSync(text.trimRight());
    final storage = FileStorage(dir.path);
    expect(await storage.loadChanges(), hasLength(3));
    expect(log().readAsStringSync(), endsWith('\n'));
  });

  test('clearing removes the log and metadata', () async {
    final storage = FileStorage(dir.path);
    final clock = TestClock.at(DateTime.utc(2026, 2, 1, 15));
    final den = await openDen(clock, storage: storage);
    await den.createFamily(
      familyName: 'Park family',
      timezone: 'UTC',
      yourName: 'Jin',
      marker: Marker.sky,
      animal: Animal.bird,
      deviceName: 'Phone',
      deviceKind: DeviceKind.phone,
    );
    await storage.clear();
    expect(await storage.loadChanges(), isEmpty);
    expect(await storage.loadMeta(), isNull);
    expect(dir.listSync(), isEmpty);
    await storage.clear();
  });

  test('metadata is replaced atomically', () async {
    final storage = FileStorage(dir.path);
    await storage.saveMeta({'counter': 1});
    await storage.saveMeta({'counter': 2, 'note': 'second'});
    expect(await storage.loadMeta(), {'counter': 2, 'note': 'second'});
    expect(File('${dir.path}${Platform.pathSeparator}meta.json.tmp').existsSync(), isFalse);
    File('${dir.path}${Platform.pathSeparator}meta.json').writeAsStringSync('{"broken": ');
    File('${dir.path}${Platform.pathSeparator}meta.json.tmp').writeAsStringSync('{"counter": 3}');
    expect(await storage.loadMeta(), {'counter': 3}, reason: 'falls back to a finished temporary file');
  });

  test('a snapshot is replaced whole, and cleared with everything else', () async {
    final storage = FileStorage(dir.path);
    expect(await storage.loadSnapshot(), isNull);
    await storage.saveSnapshot('first');
    await storage.saveSnapshot('second\nwith lines');
    expect(await storage.loadSnapshot(), 'second\nwith lines');
    expect(File('${dir.path}${Platform.pathSeparator}snapshot.json.tmp').existsSync(), isFalse);
    // A write cut short leaves a temporary file behind, never a half-written snapshot.
    File('${dir.path}${Platform.pathSeparator}snapshot.json.tmp').writeAsStringSync('half');
    expect(await FileStorage(dir.path).loadSnapshot(), 'second\nwith lines');
    await storage.clear();
    expect(await storage.loadSnapshot(), isNull);
    expect(dir.listSync(), isEmpty);
  });

  test('a device on files opens from its snapshot to the same state', () async {
    snapshotCheckDelay = Duration.zero;
    final clock = TestClock.at(DateTime.utc(2026, 2, 1, 15));
    final keys = await DeviceKeys.generate();
    final den = await openDen(clock, storage: FileStorage(dir.path), keys: keys);
    await den.createFamily(
      familyName: 'Park family',
      timezone: 'America/New_York',
      yourName: 'Jin',
      deviceName: 'Phone',
      deviceKind: DeviceKind.phone,
    );
    final list = await den.addList(title: 'Groceries', kind: ListKind.shopping);
    for (var i = 0; i < Den.snapshotEvery; i++) {
      clock.advance(const Duration(minutes: 7));
      await den.addItem(list, text: 'Item $i');
    }
    await den.debugIdle();
    expect(File('${dir.path}${Platform.pathSeparator}snapshot.json').existsSync(), isTrue);
    final export = jsonEncode(den.exportJson());
    await den.close();
    final reopened = await openDen(clock, storage: FileStorage(dir.path), keys: keys);
    expect(reopened.debugOpenedFromSnapshot, isTrue);
    expect(jsonEncode(reopened.exportJson()), export);
    await reopened.debugIdle();
    await reopened.close();
  });
}
