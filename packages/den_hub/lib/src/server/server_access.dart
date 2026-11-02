/// Who may change what is the server's (how it reaches the internet, where its backups go, when
/// it updates), and how a secret may reach it.
library;

import 'package:den_core/den_core.dart' show DeviceMode;
import 'package:den_net/den_net.dart' show DeviceRequestCheck;
import 'package:shelf/shelf.dart';

import '../context.dart';
import '../device_auth.dart';
import '../edge.dart';
import '../host.dart' show DenHost;
import '../http_util.dart';
import '../net_guard.dart' show isPublicAddress;

/// [c], when it is a parent of the server's own family (the family in the server's data
/// directory itself, whoever runs the server) on their own personal phone, as for signing in with
/// Google and Apple. Anyone else gets `403`: a parent of another family on the server
/// `host_family_only`, saying [elsewhere].
DeviceRequestCheck requireServerParent(HubContext hub, DeviceRequestCheck c, {required String message, required String elsewhere}) {
  DeviceAuth.parentOf(c, message: message);
  if (c.device!.mode != DeviceMode.personal) throw ApiError.denied(message);
  if (hub.host?.signIn.hostFamily != hub.den.deviceId) throw ApiError(403, 'host_family_only', elsewhere);
  return c;
}

/// Whether [request] came from the home network: a private, loopback or link-local address, with
/// none of the headers a proxy or tunnel adds (whatever came through Cloudflare carries them).
bool fromHomeNetwork(Request request) {
  final peer = peerAddress(request);
  if (peer == null || isPublicAddress(peer)) return false;
  for (final name in request.headers.keys) {
    final n = name.toLowerCase();
    if (n.startsWith('x-forwarded-') || n.startsWith('cf-') || n == 'forwarded' || n == 'via' || n == 'x-real-ip') return false;
  }
  return true;
}

/// Throws `403 needs_https` unless a secret (a tunnel token, a NAS's password, recovery words)
/// may arrive by [request]: over HTTPS (at a trusted proxy that says so), from this machine, or
/// from the home network, where the server is set up before it has an https address at all.
void requireSecretsSafe(HubContext hub, Request request) {
  if (arrivedOverHttps(request, hub.config.trustedProxies) || DenHost.local(request) || fromHomeNetwork(request)) return;
  hub.failed(request);
  throw ApiError(403, 'needs_https',
      'Open Den at its https address, or on the home network, to set this up: what you type here is a secret, and this '
      'connection isn\'t encrypted.');
}
