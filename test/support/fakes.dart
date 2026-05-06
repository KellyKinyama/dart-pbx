// Helpers shared across tests.

import 'package:dart_pbx/sip_client.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/transports/transport.dart';

/// Captures everything a fake transport sends, so tests can assert against it.
class FakeTransport extends SipTransport {
  FakeTransport({
    String localAddr = '198.51.100.10',
    int localPort = 12345,
    String serverAddr = '203.0.113.1',
    int serverPort = 5060,
    String proto = 'udp',
  }) : super(
          sockaddr_in(localAddr, localPort, proto),
          sockaddr_in(serverAddr, serverPort, proto),
          (String raw, {String? destIp, int? destPort}) {
            // Default no-op; replaced below.
          },
        ) {
    // Override the send closure to actually capture sends. We can't call
    // `this` until super() finished, so do it now.
    send = (String raw, {String? destIp, int? destPort}) {
      sent.add(SentMessage(raw: raw, destIp: destIp, destPort: destPort));
    };
  }

  final List<SentMessage> sent = [];

  String? get lastSent => sent.isEmpty ? null : sent.last.raw;
}

class SentMessage {
  SentMessage({required this.raw, this.destIp, this.destPort});
  final String raw;
  final String? destIp;
  final int? destPort;
}

SipMsg parse(String raw) => SipMsg()..Parse(raw);

/// Joins lines into a CRLF-terminated SIP message with the trailing blank line.
String wire(List<String> lines) => '${lines.join('\r\n')}\r\n\r\n';

SipClient testClient(String aor, FakeTransport t) =>
    SipClient(aor, t, contactUri: 'sip:$aor@${t.socket.addr}:${t.socket.port}');
