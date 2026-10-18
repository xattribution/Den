import 'dart:async';

import 'package:den_capture/den_capture.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Who reads what this device shares, besides the device itself.
enum ReaderChoice {
  /// Only this device: its own model where it has one, and Den's own reader.
  device,

  /// A model on a computer at home, through Ollama.
  home,

  /// Claude, with an API key a parent entered on this device.
  claude,
}

/// Where the Claude key lives. It never enters the family's log; it stays in this device's
/// keychain or keystore.
abstract interface class CaptureSecrets {
  Future<String?> readKey();
  Future<void> writeKey(String? key);
}

class SecureCaptureSecrets implements CaptureSecrets {
  const SecureCaptureSecrets();
  static const _name = 'den.capture.claudeKey';
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> readKey() async {
    try {
      return await _storage.read(key: _name);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> writeKey(String? key) => key == null || key.trim().isEmpty
      ? _storage.delete(key: _name)
      : _storage.write(key: _name, value: key.trim());
}

/// Holds a key in memory, for tests and the demo family.
class MemoryCaptureSecrets implements CaptureSecrets {
  MemoryCaptureSecrets([this.key]);
  String? key;

  @override
  Future<String?> readKey() async => key;

  @override
  Future<void> writeKey(String? key) async => this.key = key?.trim().isEmpty ?? true ? null : key!.trim();
}

/// This device's capture settings, set by a parent under Settings, AI and automations. The
/// family-wide choice of adding right away or showing first is the family record's `capture`.
class CaptureSettings extends ChangeNotifier {
  CaptureSettings({
    this.secrets = const SecureCaptureSecrets(),
    ReaderChoice reader = ReaderChoice.device,
    bool deviceFirst = true,
    String claudeModel = ClaudeReader.defaultModel,
    String homeAddress = '',
    String homeModel = HomeModelReader.defaultModel,
    bool hasClaudeKey = false,
  })  : _reader = reader,
        _deviceFirst = deviceFirst,
        _claudeModel = claudeModel,
        _homeAddress = homeAddress,
        _homeModel = homeModel,
        _hasClaudeKey = hasClaudeKey;

  static const _readerKey = 'den.capture.reader';
  static const _firstKey = 'den.capture.deviceFirst';
  static const _modelKey = 'den.capture.claudeModel';
  static const _homeKey = 'den.capture.homeAddress';
  static const _homeModelKey = 'den.capture.homeModel';

  static Future<CaptureSettings> load({CaptureSecrets secrets = const SecureCaptureSecrets()}) async {
    try {
      final p = await SharedPreferences.getInstance();
      return CaptureSettings(
        secrets: secrets,
        reader: ReaderChoice.values.asNameMap()[p.getString(_readerKey)] ?? ReaderChoice.device,
        deviceFirst: p.getBool(_firstKey) ?? true,
        claudeModel: p.getString(_modelKey) ?? ClaudeReader.defaultModel,
        homeAddress: p.getString(_homeKey) ?? '',
        homeModel: p.getString(_homeModelKey) ?? HomeModelReader.defaultModel,
        hasClaudeKey: (await secrets.readKey())?.isNotEmpty ?? false,
      );
    } on Object {
      return CaptureSettings(secrets: secrets);
    }
  }

  final CaptureSecrets secrets;

  ReaderChoice _reader;
  ReaderChoice get reader => _reader;
  set reader(ReaderChoice value) => _set(() => _reader = value, (p) => p.setString(_readerKey, value.name));

  bool _deviceFirst;

  /// Whether this device tries its own reading first and calls on [reader] only when it can't
  /// read something or finds nothing.
  bool get deviceFirst => _deviceFirst;
  set deviceFirst(bool value) => _set(() => _deviceFirst = value, (p) => p.setBool(_firstKey, value));

  String _claudeModel;
  String get claudeModel => _claudeModel;
  set claudeModel(String value) => _set(() => _claudeModel = value, (p) => p.setString(_modelKey, value));

  String _homeAddress;
  String get homeAddress => _homeAddress;
  set homeAddress(String value) => _set(() => _homeAddress = value.trim(), (p) => p.setString(_homeKey, value.trim()));

  String _homeModel;
  String get homeModel => _homeModel;
  set homeModel(String value) =>
      _set(() => _homeModel = value.trim().isEmpty ? HomeModelReader.defaultModel : value.trim(), (p) => p.setString(_homeModelKey, _homeModel));

  bool _hasClaudeKey;
  bool get hasClaudeKey => _hasClaudeKey;

  Future<String?> claudeKey() => secrets.readKey();

  Future<void> setClaudeKey(String? key) async {
    await secrets.writeKey(key);
    _hasClaudeKey = key != null && key.trim().isNotEmpty;
    notifyListeners();
  }

  void _set(void Function() change, Future<bool> Function(SharedPreferences) save) {
    change();
    notifyListeners();
    unawaited(SharedPreferences.getInstance().then(save).catchError((Object _) => false));
  }
}
