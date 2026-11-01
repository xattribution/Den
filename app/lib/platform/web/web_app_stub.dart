/// Off the web there is no page: nothing to ask, and every answer is "no".
String? info() => null;

Future<bool> persist() async => false;

Future<bool> holdEngine() async => true;

Future<void> waitForEngine() async {}

Future<String?> pushSubscription(String key) async => null;

Future<String?> pushState(String key) async => null;

Future<String?> subscribe(String key) async => null;

Future<void> unsubscribe() async {}

Future<void> setFamilies(String json) async {}

Future<String> share(String text) async => 'failed';

Future<String> paste() async => '{"kind":"none"}';

Future<String> copy(String text) async => 'failed';

Future<String> pickPhoto(bool camera) async => '';

void listen(void Function(String route) onOpen) {}

List<double> insets() => const [0, 0, 0, 0];

String? viewport() => null;

void onViewport(void Function(String json) onChange) {}

void diagnose(bool on) {}

String? screenInfo() => null;

bool keyboardNow() => false;

Future<String?> fetchFresh(String path) async => null;

void reload() {}
