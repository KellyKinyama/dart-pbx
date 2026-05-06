import 'dart:convert';

import 'package:dart_pbx/services/models/gateway.dart';
import 'package:dart_pbx/sip_client.dart';
import 'package:dart_pbx/sip_parser/sip.dart';

import '../config/dispartcher.dart';
//import "../requests_handler.dart";
//import 'SipMessage.dart';
//import "SipMessageFactory.dart";
import 'dart:io';
import '../globals.dart';
import 'transport.dart';

//import 'addr_port.dart';

class SipServer {
  // SipServer(String ip, {int port = 5060}){

  // }
  WebSocket? ion_sfu;
  SipServer(String ip, int port,
      {String? upstreamHost, int upstreamPort = 5060}) {
    RawDatagramSocket.bind(InternetAddress(ip), port)
        .then((RawDatagramSocket socket) {
      print('listening on udp:${socket.address.address}:${socket.port}');

      msgToClient(String data,
          {required String destIp, required int destPort}) {
        print("Sending datagram to ip: $destIp, port: $destPort");
        socket.send(data.codeUnits, InternetAddress(destIp), destPort);
      }

      // Wire the Asterisk (or other) upstream so that any unregistered AOR
      // is forwarded to the back-end PBX.
      if (upstreamHost != null && upstreamHost.isNotEmpty) {
        final upstreamTx = SipTransport(
          sockaddr_in(upstreamHost, upstreamPort, 'udp'),
          sockaddr_in(ip, port, 'udp'),
          msgToClient,
        );
        final upstreamClient = SipClient(
          'upstream',
          upstreamTx,
          contactUri: 'sip:$upstreamHost:$upstreamPort',
        );
        requestsHander.setUpstream(upstreamClient);
        print('Upstream PBX configured: udp:$upstreamHost:$upstreamPort');
      }

      initDispatcher();

      //SecureServerSocket.secureServer();

      socket.listen((RawSocketEvent e) {
        msgFromClient(String data, {String? clientAddress, int? clientPort}) {
          var tx = SipTransport(sockaddr_in(clientAddress!, clientPort!, 'udp'),
              sockaddr_in(ip, port, 'udp'), msgToClient);
          requestsHander.handle(data, tx);
        }

        gateways["10.43.0.55"] = Gateway("webrtc_gateway", 0, "10.43.0.55", 0,
            0, 0, sockaddr_in("10.43.0.55", 5070, "udp"), msgToClient);

        Datagram? d = socket.receive();
        if (d != null) {
          String message = String.fromCharCodes(d.data);
          msgFromClient(message,
              clientAddress: d.address.address, clientPort: d.port);
        }
      });
    });
  }
// WebSocket ion_sfu;
}
