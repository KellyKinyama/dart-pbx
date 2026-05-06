import 'package:dart_pbx/transports/transport.dart';

/// A registered SIP endpoint (location-service binding).
class SipClient {
  SipClient(
    this.number,
    this.transport, {
    this.contactUri,
    this.expiresAt,
  });

  String getNumber() => number;
  SipTransport getAddress() => transport;

  String number;
  SipTransport transport;

  /// Contact URI as advertised by the UA in REGISTER. Used as the request
  /// URI when the proxy needs to send the UA a request directly (e.g.
  /// OPTIONS qualify).
  String? contactUri;

  /// Absolute time at which this binding expires. `null` means no expiry was
  /// negotiated (legacy behaviour). Use [isExpired] to check.
  DateTime? expiresAt;

  /// Number of consecutive OPTIONS qualifies that received no reply. The
  /// pruner removes the binding once this exceeds a threshold.
  int missedQualifyCount = 0;

  bool isExpired([DateTime? now]) {
    if (expiresAt == null) return false;
    return (now ?? DateTime.now()).isAfter(expiresAt!);
  }
}
