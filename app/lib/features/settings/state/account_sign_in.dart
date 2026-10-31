import 'package:den_core/den_core.dart';

import '../../../platform/sync/den_network.dart';
import '../../../platform/sync/hub_api.dart';
import '../../../platform/sync/hub_client.dart';

/// A provider the family's hub signs people in with: Google or Apple.
class SignInProvider {
  const SignInProvider(this.id, this.name);

  /// `google` or `apple`.
  final String id;

  /// "Google" or "Apple".
  final String name;
}

/// A binding the hub started for this phone: the page to open in a browser (once), and the id
/// this phone reads the result back by.
class BindingStart {
  const BindingStart({required this.id, required this.provider, required this.startUrl});

  final String id;
  final String provider;
  final Uri startUrl;
}

/// Where a binding stands.
sealed class BindingState {
  const BindingState();
}

/// The browser hasn't finished signing in yet.
class BindingWaiting extends BindingState {
  const BindingWaiting();
}

/// It didn't work; [message] says why, in words for people.
class BindingFailed extends BindingState {
  const BindingFailed(this.message);
  final String message;
}

/// Signed in as [email]: [account] is what this phone writes into `member.account`.
class BindingDone extends BindingState {
  const BindingDone(this.account, this.email);
  final AccountRef account;
  final String email;
}

/// Binding a parent's Google or Apple account, from their own phone, through the family's hub
/// (docs/hub-api.md, "Binding an account"): the hub, or a fake in tests.
abstract interface class AccountSignInSource {
  /// What the hub signs in with; empty when it offers none (or is too old to).
  Future<List<SignInProvider>> providers();

  /// Starts binding through [provider].
  Future<BindingStart> start(String provider);

  /// Where [id] stands. Once it is done the hub forgets it: the result is read once.
  Future<BindingState> poll(String id);
}

/// [AccountSignInSource] through the family's hub, signed by this phone.
class HubAccountSignIn implements AccountSignInSource {
  HubAccountSignIn(DenNetwork network) : _api = HubApi(network);

  final HubApi _api;

  @override
  Future<List<SignInProvider>> providers() async {
    final Map<String, Object?> json;
    try {
      json = await _api.send('GET', '/api/v1/account/providers', missing: 'none');
    } on HubException catch (e) {
      if (e.code == 'not_found') return const [];
      rethrow;
    }
    return [
      if (json['providers'] case final List<Object?> list)
        for (final p in list)
          if (p is Map && p['id'] is String) SignInProvider(p['id']! as String, p['name'] as String? ?? p['id']! as String),
    ];
  }

  @override
  Future<BindingStart> start(String provider) async {
    final json = await _api.send('POST', '/api/v1/account/bindings', body: {'provider': provider});
    final url = Uri.tryParse(json['start_url'] as String? ?? '');
    final id = json['id'];
    if (url == null || !url.isScheme('https') || id is! String) throw const HubException('The hub gave a sign-in Den can\'t use.');
    return BindingStart(id: id, provider: provider, startUrl: url);
  }

  @override
  Future<BindingState> poll(String id) async {
    final Map<String, Object?> json;
    try {
      json = await _api.send('GET', '/api/v1/account/bindings/$id');
    } on HubException catch (e) {
      if (e.code == 'not_found') return const BindingFailed('That sign-in expired. Start again.');
      rethrow;
    }
    return switch (json['state']) {
      'waiting' => const BindingWaiting(),
      'done' => switch (AccountRef.fromJson(json['account'])) {
          final account? => BindingDone(account, json['email'] as String? ?? ''),
          null => const BindingFailed('The hub gave a sign-in Den can\'t use.'),
        },
      _ => BindingFailed(json['message'] as String? ?? 'That sign-in didn\'t work. Start again.'),
    };
  }
}
