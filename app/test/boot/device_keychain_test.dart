import 'package:den_app/platform/storage/device_keychain.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps what an earlier version saved, and writes, reads and deletes', () async {
    FlutterSecureStorage.setMockInitialValues({'den.device.keys': 'saved'});
    const keychain = DeviceKeychain();
    expect(await keychain.read('den.device.keys'), 'saved');
    await keychain.write('den.capture.claudeKey', 'sk-test');
    expect(await keychain.read('den.capture.claudeKey'), 'sk-test');
    await keychain.delete('den.capture.claudeKey');
    expect(await keychain.read('den.capture.claudeKey'), isNull);
    expect(await keychain.read('den.device.keys'), 'saved');
  });
}
