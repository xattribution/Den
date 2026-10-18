import 'package:den_capture/den_capture.dart';
import 'package:den_net/den_net.dart';
import 'package:http/http.dart' as http;

import '../net/den_network.dart';

/// This device's line to the family hub's capture service: the hub's addresses from [network],
/// every request signed with this device's key for whoever is acting on it.
HubCaptureClient hubCaptureClient(DenNetwork network, {http.Client? client}) => HubCaptureClient(
      bases: network.hubBases,
      sign: (method, url, body) async {
        final den = network.den;
        final hub = network.isHub ? den.deviceId : network.hubDevice?.id;
        if (hub == null) throw const ReaderException('This family has no hub yet.');
        return DeviceRequest.sign(keys: den.keys, method: method, url: url, body: body, hub: hub, actorId: den.actor?.id);
      },
      client: client,
    );
