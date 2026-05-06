// User Location service (Kamailio-style `usrloc`).
//
// Stores AOR → contact bindings produced by REGISTER. The proxy uses these
// when forwarding a request to a registered user.
//
// Single-binding for now (one Contact per AOR). Multi-contact / forking is a
// future extension; the API is shaped to allow it without callers changing.

import 'package:dart_pbx/sip_client.dart';

class UsrLocService {
  UsrLocService();

  final Map<String, SipClient> _bindings = {};

  /// Underlying map. Exposed so the proxy / maintainer can mutate it directly
  /// in performance-critical paths. Prefer the typed methods below in new
  /// code.
  Map<String, SipClient> get bindings => _bindings;

  SipClient? lookup(String aor) => _bindings[aor];

  void save(SipClient client) {
    _bindings[client.number] = client;
  }

  bool remove(String aor) => _bindings.remove(aor) != null;

  bool exists(String aor) => _bindings.containsKey(aor);

  Iterable<SipClient> all() => _bindings.values;

  int get count => _bindings.length;
}
