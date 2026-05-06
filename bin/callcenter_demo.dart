// Demo: dart-pbx fronting Asterisk as a call-center.
//
// Topology:
//
//      ┌─────────────┐         REGISTER + INVITE         ┌─────────────┐
//      │  SIP phone  │ ───────────────────────────────►  │  dart-pbx   │
//      │ (6001/6002) │                                   │  this app   │
//      └─────────────┘                                   └──────┬──────┘
//                          INVITE for sip:support@…             │
//                       ◄────────── (proxied) ──────────────────┘
//                                                               │
//                                                               │ INVITE for any
//                                                               │ other AOR
//                                                               ▼
//                                                       ┌─────────────┐
//                                                       │  Asterisk   │
//                                                       │  (docker)   │
//                                                       └─────────────┘
//
// Inbound call to `sip:support@<our-ip>` rings the longest-idle agent
// (6001 / 6002). All other INVITEs are forwarded to Asterisk so its
// dialplan / voicemail / queues handle them.
//
// Matches the andrius/asterisk:stable docker-compose service which
// publishes 5060/udp on the host. dart-pbx therefore listens on a
// different UDP port (5070) to avoid the collision and forwards
// upstream to 127.0.0.1:5060 by default.
//
// Run:
//   docker compose up -d asterisk
//   dart run bin/callcenter_demo.dart
//
// Required env vars (also in .env.example):
//   UPD_SERVER_ADDRESS=0.0.0.0
//   UDP_SERVER_PORT=5070
//   ASTERISK_HOST=127.0.0.1   # or the compose service name `asterisk`
//   ASTERISK_PORT=5060
//   SIP_REALM=pbx.local
//   SIP_USERS=6001:6001,6002:6002,7000:7000
//   CC_QUEUE_AOR=support
//   CC_AGENTS=6001,6002

import 'dart:io';

import 'package:dart_pbx/globals.dart';
import 'package:dart_pbx/logging.dart';
import 'package:dart_pbx/services/services.dart';
import 'package:dart_pbx/sip_client.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/transports/sip_server.dart';
import 'package:dart_pbx/transports/transport.dart';

import 'package:dotenv/dotenv.dart';

void main() async {
  final env = DotEnv(includePlatformEnvironment: true)..load();

  // ---------------- Logging ----------------
  final lvl = env['LOG_LEVEL']?.toLowerCase();
  switch (lvl) {
    case 'error':
      Log.level = LogLevel.error;
      break;
    case 'warn':
    case 'warning':
      Log.level = LogLevel.warn;
      break;
    case 'debug':
    case 'trace':
      Log.level = LogLevel.debug;
      break;
    case 'info':
      Log.level = LogLevel.info;
      break;
  }
  final dumpPath = env['SIP_DUMP_FILE'];
  if (dumpPath != null && dumpPath.isNotEmpty) {
    Log.openSipDump(dumpPath);
    Log.info('boot', 'SIP dump file: $dumpPath');
  }

  // ---------------- Auth ----------------
  final realm = env['SIP_REALM'] ?? 'pbx.local';
  final store = InMemoryCredentialsStore(realm: realm);
  final usersCsv = env['SIP_USERS'] ?? '6001:6001,6002:6002,7000:7000';
  for (final entry in usersCsv.split(',')) {
    final pair = entry.trim();
    final colon = pair.indexOf(':');
    if (colon <= 0) continue;
    store.put(pair.substring(0, colon).trim(),
        password: pair.substring(colon + 1));
  }
  final auth = AuthService(
    digest: DigestAuth(realm: realm, secret: env['SIP_AUTH_SECRET']),
    credentials: store,
  );

  // ---------------- Service registry ----------------
  final services = ServiceRegistry(auth: auth);

  // Queue + agents. Agents start with a stub transport; the REGISTER hook
  // in RequestsHandler will replace it with the real one and call login()
  // once the phone registers.
  final queueAor = env['CC_QUEUE_AOR'] ?? 'support';
  services.callcenter.registerQueue(Queue(id: queueAor));

  final stubTx = SipTransport(
    sockaddr_in('0.0.0.0', 0, 'udp'),
    sockaddr_in('0.0.0.0', 0, 'udp'),
    (String _, {String? destIp, int? destPort}) {},
  );
  final agentsCsv = env['CC_AGENTS'] ?? '6001,6002';
  for (final id in agentsCsv.split(',').map((s) => s.trim())) {
    if (id.isEmpty) continue;
    services.callcenter.addAgent(Agent(id: id, client: SipClient(id, stubTx)));
    Log.info('callcenter', 'registered agent $id (waiting for REGISTER)');
  }

  configureRequestsHandler(services: services);

  // ---------------- UDP listener with Asterisk upstream ----------------
  final udpIp = env['UPD_SERVER_ADDRESS'] ?? '0.0.0.0';
  final udpPort = int.tryParse(env['UDP_SERVER_PORT'] ?? '5070') ?? 5070;
  final asteriskHost = env['ASTERISK_HOST'] ?? '127.0.0.1';
  final asteriskPort = int.tryParse(env['ASTERISK_PORT'] ?? '5060') ?? 5060;

  Log.info('boot', 'starting dart-pbx call-center on udp:$udpIp:$udpPort');
  Log.info('boot',
      'forwarding non-queue INVITEs to Asterisk udp:$asteriskHost:$asteriskPort');
  Log.info('boot', 'queue AOR: sip:$queueAor@<this-server>');
  Log.info('boot', 'agents: $agentsCsv (must REGISTER to come online)');

  SipServer(udpIp, udpPort,
      upstreamHost: asteriskHost, upstreamPort: asteriskPort);

  // Graceful shutdown on Ctrl-C / SIGTERM.
  Future<void> shutdown(String reason) async {
    Log.warn('shutdown', 'closing services ($reason)');
    requestsHander.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown('SIGINT'));
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => shutdown('SIGTERM'));
  }
}
