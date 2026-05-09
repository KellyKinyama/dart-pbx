/// Riverpod providers for the SIP user agent and the UI-facing state
/// derived from its event streams.
///
/// Architectural notes:
///   * [sipUserAgentProvider] is a `Provider` that owns the lifetime of the
///     [SipUserAgent] + [SipFileLogger] singletons. Both are disposed when
///     the surrounding `ProviderScope` (i.e. the app) is torn down.
///   * The UA's broadcast streams are exposed as a small set of Notifiers
///     (`callsProvider`, `messagesProvider`, `logsProvider`) and a
///     `StreamProvider` (`registrationStateProvider`). Pages should read
///     from these providers instead of subscribing to streams directly.
///   * [sharedPreferencesProvider] must be overridden in `ProviderScope` at
///     app start with the value resolved from `SharedPreferences.getInstance`.
///   * [accountProvider] mirrors the persisted SIP account so the login flow
///     can update it without forcing the rest of the app to read prefs.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sip/audio/pcm_audio_sink.dart';
import '../sip/sip_file_logger.dart';
import '../sip/sip_user_agent.dart';

/// Storage key used to persist the SIP account across launches.
const sipAccountPrefsKey = 'sip_account_v1';

// ---------------------------------------------------------------------------
// Infrastructure
// ---------------------------------------------------------------------------

/// Resolved at app start by overriding in [ProviderScope].
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in ProviderScope',
  ),
);

final sipFileLoggerProvider = Provider<SipFileLogger>((ref) {
  final logger = SipFileLogger(_buildLogPath());
  try {
    logger.open();
    if (kDebugMode) {
      // ignore: avoid_print
      print('[sip] wire log: ${logger.path}');
    }
  } catch (e) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[sip] could not open wire log: $e');
    }
  }
  ref.onDispose(logger.close);
  return logger;
});

final sipUserAgentProvider = Provider<SipUserAgent>((ref) {
  final logger = ref.watch(sipFileLoggerProvider);
  final ua = SipUserAgent(
    audioSinkFactory: () => PcmAudioSink(),
    rtpPacketTap: (flow, summary) => logger.note('rtp ${flow.name} $summary'),
  );
  ua.attachFileLogger(logger);
  ref.onDispose(() {
    // Best-effort: unregister + close transport.
    ua.stop();
  });
  return ua;
});

String _buildLogPath() {
  final ts = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '-')
      .replaceAll('.', '-');
  final dir = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_sip_ua',
  );
  return '${dir.path}${Platform.pathSeparator}sip-$ts.log';
}

// ---------------------------------------------------------------------------
// Account
// ---------------------------------------------------------------------------

/// Currently active SIP account. `null` means "not signed in".
///
/// Updated by the login flow and cleared on sign-out. Mirrored to
/// `SharedPreferences` via [persistAccount] / [clearPersistedAccount].
class AccountNotifier extends Notifier<SipAccount?> {
  @override
  SipAccount? build() => null;

  void set(SipAccount? account) => state = account;
}

final accountProvider = NotifierProvider<AccountNotifier, SipAccount?>(
  AccountNotifier.new,
);

SipAccount? readPersistedAccount(SharedPreferences prefs) {
  final raw = prefs.getString(sipAccountPrefsKey);
  if (raw == null) return null;
  final parts = raw.split('|');
  if (parts.length < 4) return null;
  return SipAccount(
    serverUri: Uri.parse(parts[0]),
    domain: parts[1],
    username: parts[2],
    password: parts[3],
    displayName: parts.length > 4 && parts[4].isNotEmpty ? parts[4] : null,
    sessionExpires: parts.length > 5 ? int.tryParse(parts[5]) ?? 1800 : 1800,
    minSE: parts.length > 6 ? int.tryParse(parts[6]) ?? 90 : 90,
  );
}

Future<void> persistAccount(SharedPreferences prefs, SipAccount acc) {
  return prefs.setString(
    sipAccountPrefsKey,
    [
      acc.serverUri.toString(),
      acc.domain,
      acc.username,
      acc.password,
      acc.displayName ?? '',
      '${acc.sessionExpires}',
      '${acc.minSE}',
    ].join('|'),
  );
}

Future<void> clearPersistedAccount(SharedPreferences prefs) {
  return prefs.remove(sipAccountPrefsKey);
}

// ---------------------------------------------------------------------------
// Registration state
// ---------------------------------------------------------------------------

final registrationStateProvider = StreamProvider<RegistrationState>((ref) {
  final ua = ref.watch(sipUserAgentProvider);
  return ua.registrationStream;
});

/// Convenience: whether the UA is currently registered. Defaults to `false`
/// while the stream is loading or in error.
final isRegisteredProvider = Provider<bool>((ref) {
  final state = ref.watch(registrationStateProvider);
  return state.maybeWhen(
    data: (s) => s == RegistrationState.registered,
    orElse: () => false,
  );
});

// ---------------------------------------------------------------------------
// Calls
// ---------------------------------------------------------------------------

@immutable
class CallsState {
  const CallsState({this.recents = const [], this.everActive = const {}});
  final List<SipCall> recents;
  final Set<String> everActive;

  CallsState copyWith({List<SipCall>? recents, Set<String>? everActive}) =>
      CallsState(
        recents: recents ?? this.recents,
        everActive: everActive ?? this.everActive,
      );
}

class CallsNotifier extends Notifier<CallsState> {
  @override
  CallsState build() {
    final ua = ref.watch(sipUserAgentProvider);
    final sub = ua.callStream.listen(_onCall);
    ref.onDispose(sub.cancel);
    return const CallsState();
  }

  void _onCall(SipCall call) {
    final recents = [...state.recents]..removeWhere((c) => c.id == call.id);
    recents.insert(0, call);
    final everActive = {...state.everActive};
    if (call.state == CallState.active) everActive.add(call.id);
    if (recents.length > 50) {
      final removed = recents.removeLast();
      everActive.remove(removed.id);
    }
    state = CallsState(recents: recents, everActive: everActive);
  }

  void clear() => state = const CallsState();
}

final callsProvider = NotifierProvider<CallsNotifier, CallsState>(
  CallsNotifier.new,
);

/// Raw stream of call lifecycle events from the UA. Pages can `ref.listen`
/// this to react to incoming calls (e.g. push a CallPage route).
final callEventsProvider = StreamProvider<SipCall>((ref) {
  final ua = ref.watch(sipUserAgentProvider);
  return ua.callStream;
});

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

class MessagesNotifier extends Notifier<List<SipTextMessage>> {
  @override
  List<SipTextMessage> build() {
    final ua = ref.watch(sipUserAgentProvider);
    final sub = ua.messageStream.listen((m) => state = [m, ...state]);
    ref.onDispose(sub.cancel);
    return const [];
  }

  void clear() => state = const [];
}

final messagesProvider =
    NotifierProvider<MessagesNotifier, List<SipTextMessage>>(
      MessagesNotifier.new,
    );

// ---------------------------------------------------------------------------
// Log
// ---------------------------------------------------------------------------

class LogsNotifier extends Notifier<List<String>> {
  static const _maxEntries = 500;

  @override
  List<String> build() {
    final ua = ref.watch(sipUserAgentProvider);
    final sub = ua.logStream.listen((line) {
      final next = [line, ...state];
      if (next.length > _maxEntries) next.removeLast();
      state = next;
    });
    ref.onDispose(sub.cancel);
    return const [];
  }

  void clear() => state = const [];
}

final logsProvider = NotifierProvider<LogsNotifier, List<String>>(
  LogsNotifier.new,
);

// ---------------------------------------------------------------------------
// Buddies (derived contact list, Browser-Phone style)
// ---------------------------------------------------------------------------

/// A contact entry derived from the user's call + message history.
///
/// Buddies are not persisted independently yet; they are computed from the
/// recent calls and messages held in the providers above. The key (`peer`)
/// is the bare SIP party string we use everywhere else (e.g. `sip:200@host`
/// or just an extension that the UA will normalise on dial).
@immutable
class Buddy {
  const Buddy({
    required this.peer,
    required this.lastActivity,
    this.lastMessage,
    this.lastCall,
    this.unread = 0,
  });

  final String peer;
  final DateTime lastActivity;
  final SipTextMessage? lastMessage;
  final SipCall? lastCall;
  final int unread;

  /// Friendly name extracted from the SIP URI (`sip:user@host` -> `user`).
  String get displayName {
    var s = peer.trim();
    if (s.startsWith('sip:')) s = s.substring(4);
    final at = s.indexOf('@');
    return at > 0 ? s.substring(0, at) : s;
  }

  String get host {
    var s = peer.trim();
    if (s.startsWith('sip:')) s = s.substring(4);
    final at = s.indexOf('@');
    return at > 0 ? s.substring(at + 1) : '';
  }
}

String _peerKey(String party) {
  var s = party.trim();
  if (s.startsWith('sip:')) s = s.substring(4);
  // Strip any URI parameters / display-name angle brackets that may have
  // leaked through. We use the bare `user@host` (or just `user`) as the key.
  s = s.replaceAll(RegExp(r'[<>"]'), '');
  final semi = s.indexOf(';');
  if (semi > 0) s = s.substring(0, semi);
  return s.toLowerCase();
}

/// Currently-focused buddy (peer key) in the main pane. `null` shows the
/// welcome screen.
class SelectedBuddyNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? peer) => state = peer;
  void clear() => state = null;
}

final selectedBuddyProvider = NotifierProvider<SelectedBuddyNotifier, String?>(
  SelectedBuddyNotifier.new,
);

/// Persistent dialer input. Lives in Riverpod so the dial pad sheet can be
/// dismissed and reopened without losing the typed digits, and so other
/// surfaces (e.g. tapping a buddy's "call" button) can pre-populate it.
class DialerInputNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
  void append(String s) => state = state + s;
  void backspace() {
    if (state.isEmpty) return;
    state = state.substring(0, state.length - 1);
  }

  void clear() => state = '';
}

final dialerInputProvider = NotifierProvider<DialerInputNotifier, String>(
  DialerInputNotifier.new,
);

// ── Theme mode ──────────────────────────────────────────────────────────────

const String _kThemeModeKey = 'theme_mode_v1';

/// User-selected theme mode. Defaults to [ThemeMode.system] but persists any
/// override (light / dark) across launches via SharedPreferences.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final prefs = ref.read(sharedPreferencesProvider);
    return _decode(prefs.getString(_kThemeModeKey));
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_kThemeModeKey, _encode(mode));
  }

  /// Cycle system → light → dark → system. Used by the sidebar toggle.
  Future<void> cycle() {
    return set(switch (state) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    });
  }

  static String _encode(ThemeMode m) => switch (m) {
    ThemeMode.system => 'system',
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
  };

  static ThemeMode _decode(String? s) => switch (s) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

/// Per-peer unread counter, incremented when a new inbound message arrives
/// for a peer who is not the currently selected buddy.
class UnreadNotifier extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() {
    final ua = ref.watch(sipUserAgentProvider);
    final sub = ua.messageStream.listen((m) {
      if (m.outgoing) return;
      final key = _peerKey(m.peer);
      final selected = ref.read(selectedBuddyProvider);
      if (selected != null && _peerKey(selected) == key) return;
      state = {...state, key: (state[key] ?? 0) + 1};
    });
    ref.onDispose(sub.cancel);
    return const {};
  }

  void clearFor(String peer) {
    final key = _peerKey(peer);
    if (!state.containsKey(key)) return;
    final next = {...state}..remove(key);
    state = next;
  }

  void clearAll() => state = const {};
}

final unreadProvider = NotifierProvider<UnreadNotifier, Map<String, int>>(
  UnreadNotifier.new,
);

/// Derived list of buddies, newest activity first.
final buddiesProvider = Provider<List<Buddy>>((ref) {
  final calls = ref.watch(callsProvider).recents;
  final messages = ref.watch(messagesProvider);
  final unread = ref.watch(unreadProvider);

  // Group by peer key but remember the original (display) form so the UI
  // can show `user@host` as it was first seen.
  final originals = <String, String>{};
  final lastMsg = <String, SipTextMessage>{};
  final lastCall = <String, SipCall>{};
  final lastTs = <String, DateTime>{};

  void touch(String party, DateTime when) {
    final key = _peerKey(party);
    if (key.isEmpty) return;
    originals.putIfAbsent(key, () => party);
    final prev = lastTs[key];
    if (prev == null || when.isAfter(prev)) lastTs[key] = when;
  }

  for (final m in messages) {
    final key = _peerKey(m.peer);
    if (key.isEmpty) continue;
    final prev = lastMsg[key];
    if (prev == null || m.receivedAt.isAfter(prev.receivedAt)) {
      lastMsg[key] = m;
    }
    touch(m.peer, m.receivedAt);
  }
  for (final c in calls) {
    final key = _peerKey(c.remoteParty);
    if (key.isEmpty) continue;
    final prev = lastCall[key];
    final ts = c.startedAt ?? c.endedAt ?? DateTime.now();
    final prevTs = prev?.startedAt ?? prev?.endedAt;
    if (prev == null || (prevTs != null && ts.isAfter(prevTs))) {
      lastCall[key] = c;
    }
    touch(c.remoteParty, ts);
  }

  final keys = lastTs.keys.toList()
    ..sort((a, b) => lastTs[b]!.compareTo(lastTs[a]!));
  return [
    for (final k in keys)
      Buddy(
        peer: originals[k] ?? k,
        lastActivity: lastTs[k]!,
        lastMessage: lastMsg[k],
        lastCall: lastCall[k],
        unread: unread[k] ?? 0,
      ),
  ];
});

/// Messages filtered to a single peer thread, oldest first (chat order).
final threadProvider = Provider.family<List<SipTextMessage>, String>((
  ref,
  peer,
) {
  final key = _peerKey(peer);
  final all = ref.watch(messagesProvider);
  return all.where((m) => _peerKey(m.peer) == key).toList().reversed.toList();
});

/// Calls filtered to a single peer, newest first.
final peerCallsProvider = Provider.family<List<SipCall>, String>((ref, peer) {
  final key = _peerKey(peer);
  final all = ref.watch(callsProvider).recents;
  return all.where((c) => _peerKey(c.remoteParty) == key).toList();
});

/// High-level "line state" for a buddy, equivalent to Browser-Phone's
/// `.dotOnline` / `.dotRinging` / `.dotInUse` / `.buddyActiveCall` /
/// `.buddyActiveCallHollding` styling.
enum BuddyLineState {
  /// No active call; default presence pip.
  idle,

  /// An INVITE is in flight (incoming or outgoing) for this buddy.
  ringing,

  /// A call with this buddy is currently connected.
  inCall,

  /// A call with this buddy is connected but on hold.
  onHold,
}

/// Per-peer line state derived from recent calls, used by the buddy list
/// and the stream header to mirror the Browser-Phone visual cues.
final peerLineStateProvider = Provider.family<BuddyLineState, String>((
  ref,
  peer,
) {
  final key = _peerKey(peer);
  final recents = ref.watch(callsProvider).recents;
  for (final c in recents) {
    if (_peerKey(c.remoteParty) != key) continue;
    switch (c.state) {
      case CallState.active:
        // We don't track hold state at the call-list level yet; future
        // hook: read `ua.isHeld(c.id)` once that becomes streamable.
        return BuddyLineState.inCall;
      case CallState.incomingRinging:
      case CallState.outgoingRinging:
        return BuddyLineState.ringing;
      case CallState.ended:
      case CallState.idle:
        continue;
    }
  }
  return BuddyLineState.idle;
});
