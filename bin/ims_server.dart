// Standalone IMS Core entrypoint (3GPP TS 23.228 collocated P/I/S-CSCF + HSS).
//
// This binary spins up a single UDP transport, builds an [ImsCore], and
// provisions a small subscriber base from environment variables. It is
// the IMS counterpart of `bin/dart_pbx.dart` (which exposes the
// general-purpose SIP proxy).
//
// Required environment variables:
//
//   IMS_BIND_ADDR        listening address           (default 0.0.0.0)
//   IMS_BIND_PORT        listening UDP port          (default 5060)
//   IMS_REALM            home network realm          (default ims.local)
//   IMS_VISITED_NETWORK  P-Visited-Network-ID value  (default = realm)
//   IMS_SUBSCRIBERS      comma-separated triples
//                          impi@realm|impu1[,impu2...]|password
//                        e.g. alice@ims.local|sip:alice@ims.local|s3cret
//   IMS_OFFNET_HOST      optional BGCF / Asterisk host
//   IMS_OFFNET_PORT      optional BGCF / Asterisk port (default 5060)
//
// Run:
//   dart run bin/ims_server.dart

import 'dart:io';

import 'package:dart_pbx/ims/ims_core.dart';
import 'package:dart_pbx/sip_client.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/transports/transport.dart';
import 'package:dotenv/dotenv.dart';

void main() async {
  final env = DotEnv(includePlatformEnvironment: true)..load();

  final host = env['IMS_BIND_ADDR'] ?? '0.0.0.0';
  final port = int.tryParse(env['IMS_BIND_PORT'] ?? '') ?? 5060;
  final realm = env['IMS_REALM'] ?? 'ims.local';
  final visited = env['IMS_VISITED_NETWORK'] ?? realm;

  final core = ImsCore(
    host: host,
    port: port,
    transport: 'UDP',
    realm: realm,
    visitedNetworkId: visited,
  );

  // Subscriber provisioning.
  final subs = env['IMS_SUBSCRIBERS'] ?? '';
  if (subs.isNotEmpty) {
    for (final entry in subs.split(',,')) {
      final pieces = entry.trim().split('|');
      if (pieces.length < 3) continue;
      final impi = pieces[0].trim();
      final impus = pieces[1].split(';').map((s) => s.trim()).toList();
      final password = pieces[2];
      core.hss.provision(impi: impi, impus: impus, password: password);
      print('IMS provisioned IMPI=$impi IMPUs=$impus');
    }
  }

  final socket = await RawDatagramSocket.bind(InternetAddress(host), port);
  print('IMS Core listening on udp:$host:$port (realm=$realm)');

  // Optional off-net trunk.
  final offHost = env['IMS_OFFNET_HOST'];
  if (offHost != null && offHost.isNotEmpty) {
    final offPort = int.tryParse(env['IMS_OFFNET_PORT'] ?? '') ?? 5060;
    core.offNetGateway = SipClient(
      'offnet',
      SipTransport(
        sockaddr_in(offHost, offPort, 'udp'),
        sockaddr_in(host, port, 'udp'),
        (String data, {String? destIp, int? destPort}) {
          socket.send(data.codeUnits, InternetAddress(destIp ?? offHost),
              destPort ?? offPort);
        },
      ),
      contactUri: 'sip:$offHost:$offPort',
    );
    print('IMS off-net gateway: udp:$offHost:$offPort');
  }

  socket.listen((_) {
    final dg = socket.receive();
    if (dg == null) return;
    final raw = String.fromCharCodes(dg.data);
    final tx = SipTransport(
      sockaddr_in(dg.address.address, dg.port, 'udp'),
      sockaddr_in(host, port, 'udp'),
      (String data, {String? destIp, int? destPort}) {
        socket.send(data.codeUnits,
            InternetAddress(destIp ?? dg.address.address), destPort ?? dg.port);
      },
    );
    core.handle(raw, tx);
  });
}
