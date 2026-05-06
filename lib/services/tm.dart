// Transaction Manager service (Kamailio-style `tm`).
//
// Exposes the proxy's transaction layer for inspection. The transaction
// machinery itself lives in lib/proxy/.

import 'package:dart_pbx/proxy/transaction_layer.dart';

export 'package:dart_pbx/proxy/transaction.dart'
    show
        TxKind,
        TxState,
        Transaction,
        InviteServerTransaction,
        InviteClientTransaction,
        NonInviteServerTransaction,
        NonInviteClientTransaction;
export 'package:dart_pbx/proxy/transaction_layer.dart' show TransactionLayer;

class TmService {
  TmService(this.layer);

  final TransactionLayer layer;

  int get serverTransactionCount => layer.serverTransactions.length;
  int get clientTransactionCount => layer.clientTransactions.length;
}
