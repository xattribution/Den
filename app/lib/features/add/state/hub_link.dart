import 'package:den_capture/den_capture.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;

import '../../../platform/sync/den_network.dart';

/// This device's line to the family hub's capture service: the hub's addresses from [network],
/// every request signed with this device's key for whoever is acting on it.
HubCaptureClient hubCaptureClient(DenNetwork network, {http.Client? client}) =>
    hubCaptureClientOf(() => network, client: client);

/// The same, through whichever family's connection [network] gives at the time of each request:
/// on a device in several families, the family it shows, whose Add is writing.
HubCaptureClient hubCaptureClientOf(DenNetwork? Function() network, {http.Client? client}) => HubCaptureClient(
      bases: () async => await network()?.hubBases() ?? const <Uri>[],
      sign: (method, url, body) async {
        final net = network();
        if (net == null) throw const ReaderException('This family has no hub yet.');
        final den = net.den;
        final hub = net.isHub ? den.deviceId : net.hubDevice?.id;
        if (hub == null) throw const ReaderException('This family has no hub yet.');
        return DeviceRequest.sign(keys: den.keys, method: method, url: url, body: body, hub: hub, actorId: den.actor?.id);
      },
      client: client,
    );
