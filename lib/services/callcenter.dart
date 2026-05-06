// Call-center module.
//
// Manages a pool of agents, their availability, and selects one per inbound
// call using the longest-idle policy (the agent who has been idle for the
// most time is offered the next call).
//
// A queue is a logical AOR — when an inbound INVITE targets `queue:<id>` (or
// a configured queue alias), the proxy asks the call-center to resolve it to
// a concrete [SipClient] and forwards the call there. Transaction / dialog
// state is owned by the [StatefulProxy] as for any other call; this module
// purely answers the question "which agent should ring?".
//
// Agent state machine:
//
//      offline ──login──► idle ──assigned──► ringing ──answered──► talking
//         ▲                ▲                    │                     │
//         │                │                    │ no-answer / reject  │
//         │                └────────────────────┘                     │
//         │                                                           │
//         └───────────────── logout ◄── wrapup ◄── hangup ────────────┘
//
// The picker only considers `idle` agents and prefers the one whose
// `lastIdleAt` timestamp is oldest. After assignment, the agent becomes
// `ringing`; the proxy reports the call outcome via [onAnswered] /
// [onNoAnswer] / [onHangup] so the state machine can advance.

import 'package:dart_pbx/sip_client.dart';

enum AgentState { offline, idle, ringing, talking, wrapup }

class Agent {
  Agent({
    required this.id,
    required this.client,
    Set<String>? skills,
  })  : skills = Set<String>.from(skills ?? const <String>{}),
        lastIdleAt = DateTime.now();

  /// Stable agent identifier (extension or login).
  final String id;

  /// Endpoint to ring when the agent is offered a call.
  SipClient client;

  /// Optional skill tags. A queue with a `requiredSkill` will only consider
  /// agents whose [skills] set contains it.
  final Set<String> skills;

  AgentState state = AgentState.offline;

  /// Wall-clock time at which the agent last entered [AgentState.idle]. Used
  /// by the longest-idle picker — earlier means higher priority.
  DateTime lastIdleAt;

  /// Number of calls answered since login. Pure metric.
  int callsAnswered = 0;

  /// Number of times the agent was offered but did not answer. Used to
  /// trigger an auto-pause after a configurable threshold.
  int consecutiveNoAnswer = 0;
}

class Queue {
  Queue({
    required this.id,
    this.requiredSkill,
    this.maxRingSeconds = 30,
    this.autoPauseAfterMissed = 3,
  });

  /// Queue identifier — used as the "user" part of the queue AOR
  /// (`sip:<id>@<domain>`). Inbound INVITEs whose To-user matches this id
  /// are routed by the call-center.
  final String id;

  /// Optional skill required of any agent who can take a call from this
  /// queue.
  final String? requiredSkill;

  /// How long an offered agent may ring before the proxy should give up and
  /// re-pick. Informational here — the proxy enforces it via its CANCEL
  /// path.
  final int maxRingSeconds;

  /// After this many consecutive missed offers, the agent is auto-paused
  /// (transitioned out of [AgentState.idle]).
  final int autoPauseAfterMissed;
}

class CallCenterService {
  final Map<String, Agent> _agents = {};
  final Map<String, Queue> _queues = {};

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------

  void registerQueue(Queue q) => _queues[q.id] = q;
  Queue? queue(String id) => _queues[id];
  Iterable<Queue> get queues => _queues.values;

  void addAgent(Agent a) => _agents[a.id] = a;
  Agent? agent(String id) => _agents[id];
  Iterable<Agent> get agents => _agents.values;

  /// Updates the underlying [SipClient] for an agent (e.g. when the agent
  /// re-registers from a different device).
  void updateAgentEndpoint(String agentId, SipClient client) {
    final a = _agents[agentId];
    if (a != null) a.client = client;
  }

  // ---------------------------------------------------------------------------
  // Agent state transitions
  // ---------------------------------------------------------------------------

  void login(String agentId) {
    final a = _agents[agentId];
    if (a == null) return;
    a.state = AgentState.idle;
    a.lastIdleAt = DateTime.now();
    a.consecutiveNoAnswer = 0;
  }

  void logout(String agentId) {
    final a = _agents[agentId];
    if (a == null) return;
    a.state = AgentState.offline;
  }

  /// Manual pause (agent break) — keeps them logged in but excluded from
  /// the picker.
  void pause(String agentId) {
    final a = _agents[agentId];
    if (a == null || a.state == AgentState.offline) return;
    a.state = AgentState.wrapup;
  }

  /// Manual unpause from a [pause] — returns the agent to [AgentState.idle]
  /// at the *current* time so they go to the back of the longest-idle queue.
  void unpause(String agentId) {
    final a = _agents[agentId];
    if (a == null) return;
    a.state = AgentState.idle;
    a.lastIdleAt = DateTime.now();
  }

  // ---------------------------------------------------------------------------
  // Picking — longest idle that matches the queue's skill (if any).
  // ---------------------------------------------------------------------------

  /// Returns the longest-idle agent eligible for [queueId], or null if none
  /// is currently available. Does not mutate state — call [assign] when the
  /// proxy actually offers the call.
  Agent? pickLongestIdle(String queueId) {
    final q = _queues[queueId];
    if (q == null) return null;
    Agent? best;
    for (final a in _agents.values) {
      if (a.state != AgentState.idle) continue;
      if (q.requiredSkill != null && !a.skills.contains(q.requiredSkill)) {
        continue;
      }
      if (best == null || a.lastIdleAt.isBefore(best.lastIdleAt)) {
        best = a;
      }
    }
    return best;
  }

  /// Combined pick + assign for the common path. Returns the chosen agent or
  /// null when the queue has no available agent.
  Agent? offerCall(String queueId) {
    final picked = pickLongestIdle(queueId);
    if (picked == null) return null;
    assign(picked.id);
    return picked;
  }

  /// Marks the agent as offered (ringing). Idempotent for an already-ringing
  /// agent.
  void assign(String agentId) {
    final a = _agents[agentId];
    if (a == null) return;
    a.state = AgentState.ringing;
  }

  // ---------------------------------------------------------------------------
  // Outcomes — drive state from the proxy's transaction callbacks.
  // ---------------------------------------------------------------------------

  void onAnswered(String agentId) {
    final a = _agents[agentId];
    if (a == null) return;
    a.state = AgentState.talking;
    a.callsAnswered++;
    a.consecutiveNoAnswer = 0;
  }

  void onNoAnswer(String agentId) {
    final a = _agents[agentId];
    if (a == null) return;
    a.consecutiveNoAnswer++;
    final q = _queues.values.firstWhere(
      (qq) => qq.requiredSkill == null || a.skills.contains(qq.requiredSkill),
      orElse: () => Queue(id: '__'),
    );
    if (a.consecutiveNoAnswer >= q.autoPauseAfterMissed) {
      // Auto-pause: take the agent out of rotation until they explicitly
      // unpause.
      a.state = AgentState.wrapup;
    } else {
      a.state = AgentState.idle;
      a.lastIdleAt = DateTime.now();
    }
  }

  /// Call ended; agent goes through wrap-up and back to idle.
  void onHangup(String agentId, {Duration wrapup = Duration.zero}) {
    final a = _agents[agentId];
    if (a == null) return;
    if (wrapup == Duration.zero) {
      a.state = AgentState.idle;
      a.lastIdleAt = DateTime.now();
    } else {
      a.state = AgentState.wrapup;
      Future<void>.delayed(wrapup, () {
        if (a.state == AgentState.wrapup) {
          a.state = AgentState.idle;
          a.lastIdleAt = DateTime.now();
        }
      });
    }
  }
}
