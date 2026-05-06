// Record-Route / loose-routing service (Kamailio-style `rr`).
//
// Thin facade re-exporting the SIP-helpers used by the proxy for record-route
// insertion and loose-route consumption. Exposed as a service so application
// scripts can call them by Kamailio-familiar names.

import 'package:dart_pbx/proxy/sip_helpers.dart' as h;

class RrService {
  /// Inserts a Record-Route header for this proxy at the top of [headers].
  /// The URI must already include the `;lr` parameter for loose routing.
  void recordRoute(List<String> headers, String selfRouteUri) {
    h.addRecordRoute(headers, selfRouteUri);
  }

  /// Implements the loose-routing fix-up of RFC 3261 §16.4 step 6: if the
  /// topmost Route header points at us, remove it so the next hop is taken
  /// from either the next Route or the Request-URI.
  ///
  /// Returns true when a Route was consumed.
  bool looseRoute(List<String> headers, String selfHost, int selfPort) {
    return h.consumeTopRouteIfSelf(headers, selfHost, selfPort);
  }

  /// Reads the current Route header URIs (useful for tracing).
  List<String> routes(List<String> headers) => h.readRoutes(headers);

  /// Reads the Record-Route header URIs (used during dialog setup).
  List<String> recordRoutes(List<String> headers) =>
      h.readRecordRoutes(headers);
}
