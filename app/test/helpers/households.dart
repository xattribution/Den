import 'package:den_app/app/app_state.dart';
import 'package:den_app/app/household.dart';
import 'package:den_app/platform/storage/boot.dart';
import 'package:den_app/platform/sync/den_network.dart';
import 'package:den_app/platform/sync/local_hub.dart';
import 'package:den_app/platform/sync/net_pairing.dart';
import 'package:den_core/den_core.dart';

/// A keychain in memory.
class MemoryKeys implements KeyStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// A device's storage in memory: every log by its name ([Membership.storage]), and its keychain,
/// opened the way the app opens them ([Boot.open]).
class MemoryHouseholdStore implements HouseholdStore {
  MemoryHouseholdStore({DevicePrefs? device, this.servedBy, this.networks = true}) : _device = device;

  /// How the device looks: given, or loaded from its settings as the app does.
  DevicePrefs? _device;

  /// The hub that served this "browser", for each family's pairing (tests of joining).
  final Uri? servedBy;

  /// Whether each family gets a connection (off for screens that only draw).
  final bool networks;

  final Map<String, MemoryStorage> storages = {};
  final MemoryKeys keys = MemoryKeys();
  final List<Membership> forgotten = [];

  /// What [save] saved last.
  List<Membership>? saved;
  String? savedActive;

  MemoryStorage storage(String name) => storages.putIfAbsent(name, MemoryStorage.new);

  @override
  Future<FamilyLog> open(Membership log, {bool fresh = false}) async {
    if (fresh) {
      storages.remove(log.storage);
      await keys.delete(log.keys);
    }
    final den = await Boot.open(storage: storage(log.storage), keys: keys, keysName: log.keys, allowDemo: false);
    final network = networks
        ? DenNetwork(den, log: log.primary ? null : log, localHub: LocalHub.create(port: 0, mdns: false))
        : null;
    final device = _device ??= await DevicePrefs.load();
    final state = await AppState.load(den, network: network, device: device, key: log.primary ? null : log.pref);
    return FamilyLog(
      membership: log,
      state: state,
      pairing: network == null ? null : NetPairing(network, servedBy: servedBy),
    );
  }

  @override
  Future<void> forget(Membership log) async {
    forgotten.add(log);
    storages.remove(log.storage);
    await keys.delete(log.keys);
    await DenNetwork.forget(log);
    await AppState.forget(log.pref);
  }

  @override
  Future<void> save(List<Membership> logs, String? active) async {
    saved = [...logs];
    savedActive = active;
    await Memberships.save(logs);
    await Memberships.saveActive(active);
  }
}

/// Founds a family on [den] (this device's first parent).
Future<void> found(Den den, String name, {String you = 'Sam', String zone = 'America/Chicago'}) => den.createFamily(
      familyName: name,
      timezone: zone,
      yourName: you,
      marker: Marker.sky,
      animal: Animal.cat,
      deviceName: "$you's phone",
      deviceKind: DeviceKind.phone,
    );
