import 'dart:math';

import 'package:dart_pbx/globals.dart';
import 'package:dart_pbx/logging.dart';
import 'package:dart_pbx/proxy/proxy.dart';
import 'package:dart_pbx/proxy/sip_helpers.dart' as h;
import 'package:dart_pbx/services/services.dart';
import 'package:dart_pbx/sip_client.dart';
import 'package:dart_pbx/transports/transport.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/sip_parser/sip_message_types.dart';

final Random _rng = Random.secure();

String idGen() {
  String out = "";
  const String temp =
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  for (var x = 0; x < 9; x++) {
    out += temp[_rng.nextInt(temp.length)];
  }
  return out;
}

/// Top-level dispatcher. Owns the [ServiceRegistry] and wires it into the
/// stateful proxy. Loosely mirrors a Kamailio request_route block.
class RequestsHandler {
  RequestsHandler({
    ServiceRegistry? services,
    Duration qualifyInterval = const Duration(seconds: 30),
    int maxMissedQualify = 3,
    SipClient? upstream,
  }) : services = services ?? ServiceRegistry() {
    proxy = StatefulProxy(
      clients: this.services.usrloc.bindings,
      auth: this.services.auth?.digest,
      credentials: this.services.auth?.credentials,
      upstream: upstream,
      // Call-center pre-routing: when the inbound INVITE targets a
      // configured queue, pick the longest-idle agent and inform the
      // call-center of the call outcome so its state machine stays in sync.
      // Supports serial hunt: on no-answer / busy / decline the proxy
      // automatically tries the next-longest-idle agent.
      resolveDestination: (request) {
        final queueId = request.To.User;
        if (queueId == null) return null;
        final cc = this.services.callcenter;
        final queue = cc.queue(queueId);
        if (queue == null) return null;
        final tried = <String>{};
        DestinationDecision? buildFor(String agentId) {
          final agent = cc.agent(agentId);
          if (agent == null) return null;
          tried.add(agentId);
          return DestinationDecision(
            client: agent.client,
            ringTimeout: Duration(seconds: queue.maxRingSeconds),
            onAnswered: () => cc.onAnswered(agentId),
            onFailed: (_) => cc.onNoAnswer(agentId),
            onHangup: () => cc.onHangup(agentId),
            pickNext: () {
              // Pick the next longest-idle agent we haven't tried yet for
              // this caller.
              for (final candidate in cc.agents) {
                if (tried.contains(candidate.id)) continue;
                if (candidate.state != AgentState.idle) continue;
                if (queue.requiredSkill != null &&
                    !candidate.skills.contains(queue.requiredSkill)) {
                  continue;
                }
                cc.assign(candidate.id);
                return buildFor(candidate.id);
              }
              return null;
            },
          );
        }

        final first = cc.offerCall(queueId);
        if (first == null) return null;
        return buildFor(first.id);
      },
    );
    // Back-fill the registry with engine-bound services.
    this.services.tm = TmService(proxy.txLayer);
    this.services.dialog = DialogService(proxy.dialogLayer);

    maintainer = RegistrarMaintainer(
      clients: this.services.usrloc.bindings,
      qualify: _sendOptionsQualify,
      interval: qualifyInterval,
      maxMissedQualify: maxMissedQualify,
    )..start();
  }

  final ServiceRegistry services;

  late final StatefulProxy proxy;
  late final RegistrarMaintainer maintainer;

  /// Registers (or replaces) the upstream / Asterisk trunk. When set, every
  /// proxied INVITE is forwarded there; REGISTER stays local (location
  /// service + authentication).
  void setUpstream(SipClient? upstream) {
    proxy.upstream = upstream;
  }

  /// Stops every background timer and clears in-memory state. Call once
  /// during graceful shutdown so the Dart isolate can exit cleanly.
  void close() {
    maintainer.stop();
    proxy.txLayer.close();
    proxy.dialogLayer.close();
    _qualifying.clear();
  }

  /// Outstanding OPTIONS qualifies keyed by Call-ID.
  final Map<String, SipClient> _qualifying = {};

  // Convenience accessors.
  AuthService? get auth => services.auth;
  UsrLocService get usrloc => services.usrloc;
  RegistrarPolicy get registrar => services.registrar;

  void handle(String request, SipTransport transport) {
    // RFC 5626 §3.5.1 keep-alive: a datagram of just CRLF or CRLFCRLF.
    // Many phones (Yealink, Polycom, Linphone, ...) send this every ~25s.
    // Don't bother parsing or dumping these — just bump a counter via
    // debug log and return.
    if (request.trim().isEmpty) {
      Log.debug('sip',
          'keep-alive (${request.length}B) from ${transport.socket.addr}:${transport.socket.port}');
      return;
    }

    final sipMsg = SipMsg();
    sipMsg.Parse(request);

    if (sipMsg.Req.Method != null && sipMsg.Req.Method!.isNotEmpty) {
      final method = sipMsg.Req.Method!.toUpperCase();
      Log.debug('sip', 'request: $method');
      if (method == 'REGISTER') {
        onRegister(sipMsg, transport: transport);
        return;
      }
      final handled = proxy.handleRequest(sipMsg, transport);
      if (!handled) {
        Log.warn('sip', 'unhandled method $method');
      }
      return;
    }

    if (sipMsg.Req.StatusCode != null) {
      Log.debug(
          'sip', 'response: ${sipMsg.Req.StatusCode} ${sipMsg.Req.StatusDesc}');
      // OPTIONS qualify replies first.
      final callId = sipMsg.CallId.Value;
      if (callId != null && _qualifying.remove(callId) != null) {
        final aor = sipMsg.From.User;
        final client = aor == null ? null : usrloc.lookup(aor);
        if (client != null) {
          RegistrarMaintainer.onQualifyResponse(client);
        }
        return;
      }
      proxy.handleResponse(sipMsg, transport);
      return;
    }

    Log.warn(
        'sip',
        'unknown SIP message dropped from '
            '${transport.socket.addr}:${transport.socket.port} '
            '(${request.length}B)');
    Log.dumpSip('dropped', request,
        srcIp: transport.socket.addr, srcPort: transport.socket.port);
  }

  /// REGISTER handling with optional digest auth + RFC 3261 §10.3 expiry.
  void onRegister(SipMsg data, {SipTransport? transport}) {
    if (transport == null) return;
    Log.debug('register', 'incoming REGISTER from ${data.From.User}');

    if (auth != null) {
      final result = auth!.verifyRegister(
        authorizationHeader: _findHeaderValue(data.src ?? '', 'Authorization'),
      );
      if (result != AuthResult.ok) {
        final stale = result == AuthResult.stale;
        final challenge = auth!.challengeWww(stale: stale);
        final raw = h.buildResponse(
          data,
          code: 401,
          reason: 'Unauthorized',
          toTag: idGen(),
          extraHeaders: {'WWW-Authenticate': challenge},
        );
        _send(transport, raw);
        return;
      }
    }

    final contactExpires = int.tryParse(data.Contact.Expires ?? '');
    final headerExpires =
        int.tryParse(_findHeaderValue(data.src ?? '', 'Expires') ?? '');
    final granted = registrar.grantExpires(
      contactExpires: contactExpires,
      headerExpires: headerExpires,
    );
    if (granted == null) {
      final raw = h.buildResponse(
        data,
        code: 423,
        reason: 'Interval Too Brief',
        toTag: idGen(),
        extraHeaders: {'Min-Expires': '${registrar.minExpires}'},
      );
      _send(transport, raw);
      return;
    }

    final aor = data.From.User;
    if (aor == null) return;

    if (granted == 0) {
      usrloc.remove(aor);
      if (services.callcenter.agent(aor) != null) {
        services.callcenter.logout(aor);
      }
      _send(transport, _buildRegisterOk(data, transport, expires: 0));
      return;
    }

    final binding = SipClient(
      aor,
      transport,
      contactUri: _extractContactUri(data),
      expiresAt: DateTime.now().add(Duration(seconds: granted)),
    );
    usrloc.save(binding);

    // If this AOR is a configured call-center agent, refresh its endpoint
    // and bring them online (idle). This is what lets a phone go from
    // powered-off to ringable just by re-REGISTERing.
    final cc = services.callcenter;
    if (cc.agent(aor) != null) {
      cc.updateAgentEndpoint(aor, binding);
      cc.login(aor);
    }

    if (gateways[data.From.Host] != null) {
      // Caller may be a gateway — already registered by AOR above.
    }
    _send(transport, _buildRegisterOk(data, transport, expires: granted));
  }

  String _buildRegisterOk(SipMsg data, SipTransport transport,
      {required int expires}) {
    final finalLines = <String>[];
    final lines = data.src!.split('\r\n');
    finalLines.add(SipMessageTypes.OK);

    var contactWritten = false;
    for (var x = 1; x < lines.length; x++) {
      final lower = lines[x].toLowerCase();
      if (lower.startsWith('via')) {
        if (lines[x].contains('rport')) {
          lines[x] =
              lines[x].replaceFirst('rport', 'rport=${transport.socket.port}');
        }
        lines[x] = '${lines[x]};received=${transport.socket.addr}';
        finalLines.add(lines[x]);
      } else if (lower.startsWith('to')) {
        lines[x] = '${lines[x]};tag=${idGen()}';
        finalLines.add(lines[x]);
      } else if (lower.startsWith('contact')) {
        contactWritten = true;
        final isWs = transport.serverSocket.transport.toLowerCase() == 'ws' ||
            transport.serverSocket.transport.toLowerCase() == 'wss';
        if (isWs) {
          lines[x] =
              'Contact: <sip:${data.From.User!}@${transport.serverSocket.addr}:${transport.serverSocket.port};transport=${transport.serverSocket.transport.toUpperCase()}>;expires=$expires';
        } else if (lines[x].contains('expires=')) {
          lines[x] =
              lines[x].replaceFirst(RegExp(r'expires=\d+'), 'expires=$expires');
        } else {
          lines[x] = '${lines[x]};expires=$expires';
        }
        finalLines.add(lines[x]);
      } else if (lower.startsWith('expires:')) {
        continue;
      } else {
        finalLines.add(lines[x]);
      }
    }
    if (!contactWritten) {
      finalLines.add('Expires: $expires');
    }
    finalLines.add('\r\n');
    return finalLines.join('\r\n');
  }

  String? _extractContactUri(SipMsg data) {
    final user = data.Contact.User ?? data.From.User;
    final host = data.Contact.Host;
    final port = data.Contact.Port;
    if (user == null || host == null) return null;
    final portPart = port == null ? '' : ':$port';
    final tran = data.Contact.Tran;
    final tranPart = tran == null ? '' : ';transport=$tran';
    return 'sip:$user@$host$portPart$tranPart';
  }

  void _sendOptionsQualify(SipClient client) {
    final transport = client.transport;
    final dest = client.contactUri ?? 'sip:${client.number}';
    final selfHost = transport.serverSocket.addr;
    final selfPort = transport.serverSocket.port;
    final selfProto = transport.serverSocket.transport.toUpperCase();
    final branch = h.generateBranch();
    final callId = h.generateCallId(selfHost);
    final fromTag = h.generateTag();
    final cseq = _rng.nextInt(1 << 30);

    final lines = <String>[
      'OPTIONS $dest SIP/2.0',
      'Via: SIP/2.0/$selfProto $selfHost:$selfPort;branch=$branch;rport',
      'Max-Forwards: 70',
      'From: <sip:ping@$selfHost>;tag=$fromTag',
      'To: <$dest>',
      'Call-ID: $callId',
      'CSeq: $cseq OPTIONS',
      'Contact: <sip:ping@$selfHost:$selfPort;transport=$selfProto>',
      'User-Agent: dart-pbx',
      'Accept: application/sdp',
      'Content-Length: 0',
      '',
      '',
    ];
    final raw = lines.join('\r\n');
    _qualifying[callId] = client;
    _send(transport, raw);
  }

  void _send(SipTransport transport, String raw) {
    if (transport.serverSocket.transport == 'udp') {
      transport.send(raw,
          destIp: transport.socket.addr, destPort: transport.socket.port);
    } else {
      transport.send(raw);
    }
  }

  static String? _findHeaderValue(String raw, String name) {
    final headers = raw.split('\r\n');
    final needle = name.toLowerCase();
    for (final hdr in headers) {
      final colon = hdr.indexOf(':');
      if (colon <= 0) continue;
      if (hdr.substring(0, colon).trim().toLowerCase() == needle) {
        return hdr.substring(colon + 1).trim();
      }
    }
    return null;
  }
}
