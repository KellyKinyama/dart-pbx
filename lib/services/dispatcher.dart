// Dispatcher service (Kamailio-style `dispatcher`).
//
// Holds groups (sets) of upstream destinations and selects one per call using
// a configurable algorithm. A destination's `state` reflects probe results so
// dead nodes are skipped.
//
// Replaces the older lib/config/dispartcher.dart. Kept transport-agnostic:
// each Destination carries a `sockaddr_in` plus a sender callback.

import 'dart:math';

import 'package:dart_pbx/sip_parser/sip.dart';

enum DispatcherState { unknown, up, down, probing }

enum DispatcherAlgorithm {
  /// Hash of Call-ID across the active set.
  hashCallId,

  /// Plain round-robin within a set (next pointer kept per set).
  roundRobin,

  /// First active destination wins; failover to next on probe failure.
  priority,
}

class Destination {
  Destination({
    required this.id,
    required this.address,
    required this.send,
    this.priority = 0,
    this.attrs = const {},
  });

  final String id;
  final sockaddr_in address;
  final void Function(String raw) send;
  final int priority;
  final Map<String, String> attrs;

  DispatcherState state = DispatcherState.unknown;
  int consecutiveFailures = 0;
}

class DispatcherSet {
  DispatcherSet({
    required this.id,
    this.algorithm = DispatcherAlgorithm.roundRobin,
  });

  final int id;
  final DispatcherAlgorithm algorithm;
  final List<Destination> _members = [];
  int _rrCursor = 0;

  void add(Destination d) {
    _members.add(d);
    if (algorithm == DispatcherAlgorithm.priority) {
      _members.sort((a, b) => a.priority.compareTo(b.priority));
    }
  }

  List<Destination> get members => List.unmodifiable(_members);

  Iterable<Destination> active() =>
      _members.where((d) => d.state != DispatcherState.down);
}

class DispatcherService {
  final Map<int, DispatcherSet> _sets = {};

  DispatcherSet ensureSet(int setId,
      {DispatcherAlgorithm algorithm = DispatcherAlgorithm.roundRobin}) {
    return _sets.putIfAbsent(
        setId, () => DispatcherSet(id: setId, algorithm: algorithm));
  }

  void addDestination(int setId, Destination d) {
    ensureSet(setId).add(d);
  }

  Iterable<DispatcherSet> get sets => _sets.values;

  /// Selects a destination from the named set. Returns null if no active
  /// member is available.
  ///
  /// [hashKey] is required for [DispatcherAlgorithm.hashCallId] (typically
  /// the request's Call-ID).
  Destination? select(int setId, {String? hashKey}) {
    final set = _sets[setId];
    if (set == null) return null;
    final live = set.active().toList();
    if (live.isEmpty) return null;
    switch (set.algorithm) {
      case DispatcherAlgorithm.hashCallId:
        final key = hashKey ?? '';
        final h =
            key.codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0x7fffffff);
        return live[h % live.length];
      case DispatcherAlgorithm.roundRobin:
        final pick = live[set._rrCursor % live.length];
        set._rrCursor = (set._rrCursor + 1) % live.length;
        return pick;
      case DispatcherAlgorithm.priority:
        return live.first;
    }
  }

  /// Marks a destination as down after a failed probe.
  void markDown(Destination d) {
    d.state = DispatcherState.down;
    d.consecutiveFailures += 1;
  }

  /// Marks a destination as up (e.g. successful OPTIONS probe).
  void markUp(Destination d) {
    d.state = DispatcherState.up;
    d.consecutiveFailures = 0;
  }
}

/// Cheap stable hash for [DispatcherAlgorithm.hashCallId] callers that don't
/// have a Call-ID yet — falls back to a per-process random salt.
String defaultDispatchKey([String? seed]) =>
    seed ?? Random().nextInt(1 << 32).toRadixString(16);
