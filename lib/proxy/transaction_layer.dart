// Transaction layer: keep track of every live server/client transaction and
// match incoming messages against them per RFC 3261 §17.2.3 / §17.1.3.
//
// For requests (incoming downstream → us as UAS / us as proxy server side):
//   key = topmost-Via.branch + ";" + topmost-Via.sent-by + ";" + method
//   ACK to a non-2xx matches the original INVITE server transaction (method
//   substituted with "INVITE").
//
// For responses (incoming upstream → us as UAC / us as proxy client side):
//   key = topmost-Via.branch + ";" + cseq.method
// Because we strip our own Via when forwarding responses downstream, the
// topmost Via on an arriving response is the one we inserted when sending the
// matching request, so the lookup is direct.

import 'package:dart_pbx/sip_parser/sip.dart';

import 'sip_helpers.dart';
import 'transaction.dart';

class TransactionLayer {
  final Map<String, Transaction> _serverTx = {};
  final Map<String, Transaction> _clientTx = {};

  /// Key used to index a server transaction. ACK is normalised to INVITE so
  /// the lookup hits the original server transaction (RFC 3261 §17.2.3).
  static String? serverKey(SipMsg request) {
    final via = topVia(request);
    if (via == null || via.Branch == null || via.Branch!.isEmpty) return null;
    var method = requestMethod(request);
    if (method == null) return null;
    if (method == 'ACK') method = 'INVITE';
    return '${via.Branch};${sentBy(via)};$method';
  }

  /// Key used to match a response to its client transaction.
  static String? clientKeyFromResponse(SipMsg response) {
    final via = topVia(response);
    final cseq = cseqMethod(response);
    if (via == null || via.Branch == null || cseq == null) return null;
    return '${via.Branch};$cseq';
  }

  /// Key used when *creating* a client transaction, before the response comes
  /// back. [branch] must be the branch we placed on the outbound Via.
  static String clientKeyFromOutbound(String branch, String method) =>
      '$branch;${method.toUpperCase()}';

  Transaction? matchServer(SipMsg request) {
    final k = serverKey(request);
    return k == null ? null : _serverTx[k];
  }

  Transaction? matchClient(SipMsg response) {
    final k = clientKeyFromResponse(response);
    return k == null ? null : _clientTx[k];
  }

  void addServer(Transaction tx) {
    _serverTx[tx.id] = tx;
    tx.onTerminate = () => _serverTx.remove(tx.id);
  }

  void addClient(Transaction tx) {
    _clientTx[tx.id] = tx;
    tx.onTerminate = () => _clientTx.remove(tx.id);
  }

  Iterable<Transaction> get serverTransactions => _serverTx.values;
  Iterable<Transaction> get clientTransactions => _clientTx.values;

  /// Cancels every live transaction's timers and clears the layer. Used
  /// during graceful shutdown so the process can exit without leaving
  /// scheduled microtasks behind.
  void close() {
    for (final tx in _serverTx.values.toList()) {
      try {
        tx.terminate();
      } catch (_) {}
    }
    for (final tx in _clientTx.values.toList()) {
      try {
        tx.terminate();
      } catch (_) {}
    }
    _serverTx.clear();
    _clientTx.clear();
  }
}
