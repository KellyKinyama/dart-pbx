// Registrar policy + background maintenance.
//
// Responsibilities:
//   * Parse the requested expiry from a REGISTER (per-Contact `expires=` param,
//     falling back to the top-level `Expires` header, falling back to a
//     configurable default).
//   * Clamp it to [minExpires]..[maxExpires] and emit 423 Interval Too Brief
//     when below [minExpires].
//   * Periodically prune expired bindings and OPTIONS-qualify the survivors;
//     remove bindings whose UA stops responding for [maxMissedQualify] rounds.
//
// This module is transport-agnostic: callers supply the [Map<String,SipClient>]
// of bindings and a `sender` that knows how to push raw bytes to a binding.

import 'dart:async';
import 'dart:math';

import 'package:dart_pbx/sip_client.dart';

class RegistrarPolicy {
  RegistrarPolicy({
    this.defaultExpires = 3600,
    this.minExpires = 60,
    this.maxExpires = 7200,
  });

  /// Used when the UA omits both `Contact;expires=` and `Expires`.
  final int defaultExpires;

  /// Lower bound. Requests below this are rejected with 423 Interval Too Brief
  /// and a `Min-Expires: <minExpires>` header.
  final int minExpires;

  /// Upper bound. Anything larger is silently clamped.
  final int maxExpires;

  /// Resolves the granted expiry for a REGISTER.
  ///
  /// Returns `null` when the request asked for a value below [minExpires]; the
  /// caller should respond 423.
  /// A value of `0` is allowed and means "unregister" — the caller should
  /// remove the binding.
  int? grantExpires({int? contactExpires, int? headerExpires}) {
    final raw = contactExpires ?? headerExpires ?? defaultExpires;
    if (raw == 0) return 0;
    if (raw < minExpires) return null;
    return min(raw, maxExpires);
  }
}

/// Periodically removes expired bindings and OPTIONS-pings live ones.
class RegistrarMaintainer {
  RegistrarMaintainer({
    required this.clients,
    required this.qualify,
    this.interval = const Duration(seconds: 30),
    this.maxMissedQualify = 3,
  });

  final Map<String, SipClient> clients;

  /// Sends an OPTIONS to the binding. Implementations should arm a short
  /// timeout and call [onQualifyResponse] / [onQualifyTimeout] accordingly.
  final void Function(SipClient client) qualify;

  final Duration interval;
  final int maxMissedQualify;

  Timer? _timer;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    final now = DateTime.now();
    final dead = <String>[];

    clients.forEach((aor, client) {
      if (client.isExpired(now)) {
        dead.add(aor);
        return;
      }
      if (client.missedQualifyCount >= maxMissedQualify) {
        dead.add(aor);
        return;
      }
      // Optimistically count this round as missed; reset to 0 on response.
      client.missedQualifyCount += 1;
      qualify(client);
    });

    for (final aor in dead) {
      clients.remove(aor);
    }
  }

  /// Call when an OPTIONS response is matched back to a binding.
  static void onQualifyResponse(SipClient client) {
    client.missedQualifyCount = 0;
  }
}
