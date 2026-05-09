// Interrogating-CSCF (I-CSCF) — TS 24.229 §5.3.
//
// The I-CSCF is the entry point of the home network. Its single job is to
// look up the right S-CSCF (via the HSS Cx interface) and forward the
// request to it. In our collocated topology Cx is an in-process method
// call on [HomeSubscriberServer].
//
// What this class does:
//
//   * REGISTER from P-CSCF → Cx UAR → returns the assigned S-CSCF or, on
//     first registration, a capability set the I-CSCF must use to pick
//     one. Then forwards the REGISTER to that S-CSCF.
//   * Initial non-REGISTER for terminating routing → Cx LIR → returns the
//     S-CSCF currently serving the called IMPU. Forwards there. If the
//     user is not registered, the I-CSCF rejects with 404 (or could route
//     to a "scscf for unregistered services" — out of scope here).

import 'package:dart_pbx/logging.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/transports/transport.dart';
import 'package:dart_pbx/proxy/sip_helpers.dart' as h;

import 'hss.dart';

class Icscf {
  Icscf({
    required this.hss,
    required this.toScscf,
    required this.replyLocal,
  });

  final HomeSubscriberServer hss;

  /// Forwards [request] to the named S-CSCF. The dispatcher (the IMS Core)
  /// resolves the S-CSCF by name to the actual handler.
  void Function(String scscfName, SipMsg request, SipTransport inbound) toScscf;

  /// Send a final response back through the inbound chain (P-CSCF → UE).
  /// The implementation is supplied by the IMS Core; the I-CSCF does not
  /// know about transports.
  void Function(SipMsg response) replyLocal;

  void onRequest(SipMsg request, SipTransport inbound) {
    final method = request.Req.Method?.toUpperCase();
    if (method == null) return;

    if (method == 'REGISTER') {
      _handleRegister(request, inbound);
      return;
    }
    _handleInitialRequest(request, inbound);
  }

  // -------------------------------------------------------------------------
  // REGISTER → Cx UAR → forward to S-CSCF
  // -------------------------------------------------------------------------

  void _handleRegister(SipMsg request, SipTransport inbound) {
    final impu = _impuOfTo(request);
    final impi = _impiOf(request) ?? hss.impiFor(impu ?? '') ?? impu;
    if (impu == null || impi == null) {
      _reject(request, 400, 'Bad Request — Missing IMPU');
      return;
    }

    // Emergency REGISTER (TS 24.229 §5.3.2.1): the I-CSCF skips Cx UAR
    // entirely and forwards directly to a designated S-CSCF, even if the
    // IMPU is not provisioned in the HSS. We forward to the *first*
    // S-CSCF in the pool (collocated mode only has one).
    if (_isEmergencyRegister(request)) {
      final pool = hss.scscfPool;
      if (pool.isEmpty) {
        _reject(request, 600, 'No S-CSCF Available');
        return;
      }
      Log.debug(
          'ims.icscf', 'emergency REGISTER IMPU=$impu → S-CSCF=${pool.first}');
      toScscf(pool.first, request, inbound);
      return;
    }

    final uaa = hss.userAuthorization(impi: impi, impu: impu);
    String? targetScscf;
    switch (uaa.result) {
      case UarResult.userUnknown:
        Log.warn('ims.icscf', 'UAR: IMPI=$impi IMPU=$impu unknown');
        _reject(request, 403, 'Forbidden — User Unknown');
        return;
      case UarResult.subsequentRegistration:
        targetScscf = uaa.scscfName;
        break;
      case UarResult.firstRegistration:
        // Pick first capability — single-S-CSCF deployments have one.
        if (uaa.capabilities == null || uaa.capabilities!.isEmpty) {
          _reject(request, 600, 'No S-CSCF Available');
          return;
        }
        targetScscf = uaa.capabilities!.first;
        break;
    }
    Log.debug(
        'ims.icscf', 'REGISTER IMPI=$impi IMPU=$impu → S-CSCF=$targetScscf');
    toScscf(targetScscf!, request, inbound);
  }

  // -------------------------------------------------------------------------
  // Terminating side → Cx LIR → forward to serving S-CSCF
  // -------------------------------------------------------------------------

  void _handleInitialRequest(SipMsg request, SipTransport inbound) {
    // Emergency request — forward to first S-CSCF without LIR.
    if (_isEmergencyRequest(request)) {
      final pool = hss.scscfPool;
      if (pool.isEmpty) {
        _reject(request, 600, 'No S-CSCF Available');
        return;
      }
      Log.debug('ims.icscf',
          'emergency request ${request.Req.Method} → S-CSCF=${pool.first}');
      toScscf(pool.first, request, inbound);
      return;
    }
    final impu = _impuOfTo(request);
    if (impu == null) {
      _reject(request, 400, 'Bad Request — Missing R-URI');
      return;
    }
    final lia = hss.locationInformation(impu: impu);
    switch (lia.result) {
      case LirResult.userUnknown:
        _reject(request, 404, 'Not Found');
        return;
      case LirResult.notRegistered:
        _reject(request, 480, 'Temporarily Unavailable');
        return;
      case LirResult.served:
        toScscf(lia.scscfName!, request, inbound);
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  void _reject(SipMsg request, int code, String reason) {
    final raw = h.buildResponse(
      request,
      code: code,
      reason: reason,
      toTag: h.generateTag(),
    );
    final mutated = SipMsg()..Parse(raw);
    replyLocal(mutated);
  }

  /// Returns the IMPU as `sip:user@host` from the To header.
  String? _impuOfTo(SipMsg request) {
    final user = request.To.User;
    final host = request.To.Host;
    if (user == null || host == null) return null;
    return 'sip:$user@$host';
  }

  /// Returns the IMPI from an Authorization header (Digest username), or
  /// null when no auth header is present (first-leg REGISTER).
  String? _impiOf(SipMsg request) {
    final user = request.Auth.username;
    if (user != null && user.isNotEmpty) return user;
    return null;
  }

  /// True when the REGISTER carries an emergency indication
  /// (TS 24.229 §5.1.6.2 / RFC 5031): `;sos` Contact param or
  /// `urn:service:sos` in the Request-URI / To.
  bool _isEmergencyRegister(SipMsg request) => _isEmergencyRequest(request);

  bool _isEmergencyRequest(SipMsg request) {
    final raw = request.src ?? '';
    final headers = h.splitMessage(raw).headers;
    for (final line in headers) {
      final lower = line.toLowerCase();
      if (lower.startsWith('contact:') || lower.startsWith('contact ')) {
        if (RegExp(r';\s*sos(?:[;,>=\s]|$)').hasMatch(lower)) return true;
      }
      if (lower.startsWith('to:') || lower.startsWith('to ')) {
        if (lower.contains('urn:service:sos')) return true;
      }
    }
    final reqUri = request.Req.Src ?? '';
    return reqUri.toLowerCase().contains('urn:service:sos');
  }
}
