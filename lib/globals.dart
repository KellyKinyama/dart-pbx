import 'dart:io';

import 'package:dart_pbx/handlers/requests_handlers.dart';
import 'package:dart_pbx/services/services.dart';
import 'package:dart_pbx/services/models/gateway.dart' as gw;
import 'package:dart_pbx/sip_parser/sip.dart';

WebSocket? webSocket;
typedef SipMessage = SipMsg;
Map<String, gw.Gateway> gateways = {};

/// Top-level dispatcher used by every transport listener. Replace via
/// [configureRequestsHandler] before binding sockets to enable digest auth /
/// dispatcher / etc.
RequestsHandler requestsHander = RequestsHandler();

/// Replaces the default [requestsHander] with one wired to a fully-built
/// [ServiceRegistry]. Safe to call once at startup.
void configureRequestsHandler({required ServiceRegistry services}) {
  requestsHander = RequestsHandler(services: services);
}
