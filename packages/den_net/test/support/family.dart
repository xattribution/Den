import 'dart:async';
import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

import 'channels.dart';

bool? _ready;

/// Whether den_core's engine works yet (its bodies were being written alongside den_net).
Future<bool> denCoreReady() async {
  if (_ready != null) return _ready!;
  try {
    final den = await openDen();
    await den.createFamily(
      familyName: 'Probe',
      timezone: 'America/Chicago',
      yourName: 'P',
      marker: Marker.blue,
      animal: Animal.cat,
      deviceName: 'probe',
      deviceKind: DeviceKind.phone,
    );
    _ready = den.hasFamily && den.isApproved;
  } on UnimplementedError {
    _ready = false;
  }
  return _ready!;
}

/// Skips the calling test when den_core isn't implemented yet. Returns true when skipped.
Future<bool> skipUnlessDenCore() async {
  if (await denCoreReady()) return false;
  markTestSkipped('den_core is not implemented yet (Den.open or createFamily throws UnimplementedError)');
  return true;
}

Future<Den> openDen() async => Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate());

/// A family founded on one parent's phone.
class TestFamily {
  TestFamily._(this.founder, this.parent);

  final Den founder;

  /// The founding parent's member id.
  final String parent;

  static Future<TestFamily> create({String name = 'Pat'}) async {
    final den = await openDen();
    await den.createFamily(
      familyName: 'The Parks',
      timezone: 'America/Chicago',
      yourName: name,
      marker: Marker.blue,
      animal: Animal.cat,
      deviceName: '$name phone',
      deviceKind: DeviceKind.phone,
    );
    return TestFamily._(den, den.owner!.id);
  }

  String get founderPubkey => founder.keys.pubkey;

  /// A new device whose join request the founder approved out of band (no pairing session);
  /// it holds nothing but its own request until it syncs.
  Future<Den> approvedDevice({
    String? member,
    DeviceMode mode = DeviceMode.personal,
    DeviceKind kind = DeviceKind.phone,
    String name = 'device',
    Den? approver,
  }) async {
    final by = approver ?? founder;
    final den = await openDen();
    await den.requestJoin(
      familyId: founder.familyId!,
      founderPubkey: founderPubkey,
      deviceName: name,
      kind: kind,
      mode: mode,
    );
    await by.ingest(den.changesSince(const {}));
    await by.approveDevice(den.deviceId, member: member, mode: mode);
    return den;
  }
}

/// Connects [client] to [server] over an in-memory channel.
Future<SyncPeer> link(SyncNode server, SyncNode client, {bool pin = true}) async {
  final p = pipe<dynamic>();
  unawaited(server.serve(p.b));
  return client.connect(p.a, expectDevice: pin ? server.den.deviceId : null);
}

String exportOf(Den den) => const JsonEncoder.withIndent(' ').convert(den.exportJson());

/// Waits until every den exports the same JSON.
Future<void> converge(List<Den> dens, {Duration timeout = const Duration(seconds: 15)}) async {
  try {
    await eventually(() => dens.map(exportOf).toSet().length == 1, timeout: timeout);
  } on TimeoutException {
    fail('replicas did not converge:\n${dens.map(exportOf).join('\n-----\n')}');
  }
}

/// UTC milliseconds for a time on 2026-10-20.
int at(int hour, [int minute = 0]) => DateTime.utc(2026, 10, 20, hour, minute).millisecondsSinceEpoch;

/// A change signed by [keys] that no API would write, for attacks.
Future<Change> forgeChange({
  required DeviceKeys keys,
  required String deviceId,
  required int counter,
  required String type,
  required String rid,
  required Map<String, Object?> fields,
  String space = 'f',
  String? actor,
}) async {
  final unsigned = Change(
    id: '$deviceId:$counter',
    space: space,
    hlc: Hlc(DateTime.now().millisecondsSinceEpoch, 0, deviceId),
    type: type,
    rid: rid,
    fields: fields,
    device: deviceId,
    actor: actor,
    sig: '',
  );
  return Change(
    id: unsigned.id,
    space: unsigned.space,
    hlc: unsigned.hlc,
    type: type,
    rid: rid,
    fields: fields,
    device: deviceId,
    actor: actor,
    sig: await keys.sign(unsigned.signedBytes),
  );
}

int maxOwnCounter(Den den) =>
    den.changesSince(const {}).where((c) => c.device == den.deviceId).fold(0, (m, c) => c.counter > m ? c.counter : m);
