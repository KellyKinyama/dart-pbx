/// SIP transports.
///
/// Two pluggable implementations:
///
///  * [SipWebSocketTransport] — `ws://` / `wss://` to the dart-pbx WS server
///    (Sec-WebSocket-Protocol: sip).
///  * [SipUdpTransport]       — RFC 3261 §18 UDP, one datagram per message.
///
/// Both expose the same surface ([SipTransport]) so the user agent doesn't
/// care which one it talks over.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import 'sip_message.dart';

enum TransportState { disconnected, connecting, connected }

abstract class SipTransport {
  Stream<TransportState> get state;
  Stream<SipMessage> get messages;
  bool get isConnected;

  /// Upper-case transport token used in Via / Contact (`WS`, `WSS`, `UDP`).
  String get protocol;

  /// Public host the UA should advertise in Via/Contact.
  String get localHost;

  /// Public port. Returns 0 to mean "omit".
  int get localPort;

  Future<void> connect();
  Future<void> close();

  void send(SipMessage message);

  /// Raw send used for RFC 5626 CRLF keep-alives over WS.
  void sendRaw(String raw);

  /// Build the right transport for [serverUri].
  ///
  ///   * ws://host:port  -> [SipWebSocketTransport]
  ///   * wss://host:port -> [SipWebSocketTransport]
  ///   * sip:host:port   -> [SipUdpTransport]
  static SipTransport forUri(Uri serverUri) {
    final scheme = serverUri.scheme.toLowerCase();
    if (scheme == 'ws' || scheme == 'wss') {
      return SipWebSocketTransport(uri: serverUri);
    }
    if (scheme == 'sip' || scheme.isEmpty) {
      final host = serverUri.host.isEmpty ? serverUri.path : serverUri.host;
      final port = serverUri.hasPort ? serverUri.port : 5060;
      return SipUdpTransport(remoteHost: host, remotePort: port);
    }
    throw UnsupportedError('Unsupported SIP transport scheme: $scheme');
  }
}

// ---------------------------------------------------------------------------
// WebSocket transport.
// ---------------------------------------------------------------------------

class SipWebSocketTransport implements SipTransport {
  SipWebSocketTransport({required this.uri});

  final Uri uri;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final _stateCtl = StreamController<TransportState>.broadcast();
  final _messageCtl = StreamController<SipMessage>.broadcast();

  @override
  Stream<TransportState> get state => _stateCtl.stream;
  @override
  Stream<SipMessage> get messages => _messageCtl.stream;
  @override
  bool get isConnected => _channel != null;
  @override
  String get protocol => uri.scheme.toUpperCase();
  @override
  String get localHost => uri.host;
  @override
  int get localPort => uri.hasPort ? uri.port : 0;

  @override
  Future<void> connect() async {
    if (_channel != null) return;
    _stateCtl.add(TransportState.connecting);
    try {
      _channel = IOWebSocketChannel.connect(uri, protocols: const ['sip']);
      _sub = _channel!.stream.listen(
        _onData,
        onError: (_) => _stateCtl.add(TransportState.disconnected),
        onDone: () {
          _channel = null;
          _stateCtl.add(TransportState.disconnected);
        },
        cancelOnError: false,
      );
      _stateCtl.add(TransportState.connected);
    } catch (_) {
      _stateCtl.add(TransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    _stateCtl.add(TransportState.disconnected);
  }

  @override
  void send(SipMessage message) => sendRaw(message.encode());

  @override
  void sendRaw(String raw) {
    final ch = _channel;
    if (ch == null) throw StateError('transport not connected');
    ch.sink.add(raw);
  }

  void _onData(dynamic data) {
    try {
      final raw = data is String ? data : utf8.decode(data as List<int>);
      if (raw.trim().isEmpty) return;
      _messageCtl.add(SipMessage.parse(raw));
    } catch (_) {
      /* drop malformed */
    }
  }
}

// ---------------------------------------------------------------------------
// UDP transport.
// ---------------------------------------------------------------------------

class SipUdpTransport implements SipTransport {
  SipUdpTransport({
    required this.remoteHost,
    required this.remotePort,
    this.localBind,
    this.localBindPort = 0,
  });

  final String remoteHost;
  final int remotePort;
  final String? localBind;
  final int localBindPort;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  InternetAddress? _remoteAddr;

  final _stateCtl = StreamController<TransportState>.broadcast();
  final _messageCtl = StreamController<SipMessage>.broadcast();

  @override
  Stream<TransportState> get state => _stateCtl.stream;
  @override
  Stream<SipMessage> get messages => _messageCtl.stream;
  @override
  bool get isConnected => _socket != null;
  @override
  String get protocol => 'UDP';

  @override
  String get localHost {
    final s = _socket;
    if (s == null) return localBind ?? '0.0.0.0';
    final a = s.address.address;
    if (a == '0.0.0.0' || a == '::') return localBind ?? a;
    return a;
  }

  @override
  int get localPort => _socket?.port ?? localBindPort;

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    _stateCtl.add(TransportState.connecting);
    try {
      final bind = localBind == null
          ? InternetAddress.anyIPv4
          : InternetAddress(localBind!);
      _socket = await RawDatagramSocket.bind(bind, localBindPort);
      try {
        _remoteAddr = InternetAddress(remoteHost);
      } catch (_) {
        final list = await InternetAddress.lookup(remoteHost);
        if (list.isEmpty) {
          throw const SocketException('Cannot resolve remote host');
        }
        _remoteAddr = list.first;
      }
      _sub = _socket!.listen(_onEvent);
      _stateCtl.add(TransportState.connected);
    } catch (_) {
      _stateCtl.add(TransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
    _remoteAddr = null;
    _stateCtl.add(TransportState.disconnected);
  }

  @override
  void send(SipMessage message) => sendRaw(message.encode());

  @override
  void sendRaw(String raw) {
    final s = _socket;
    final r = _remoteAddr;
    if (s == null || r == null) throw StateError('transport not connected');
    s.send(utf8.encode(raw), r, remotePort);
  }

  void _onEvent(RawSocketEvent ev) {
    if (ev != RawSocketEvent.read) return;
    final s = _socket;
    if (s == null) return;
    final dg = s.receive();
    if (dg == null) return;
    try {
      final raw = utf8.decode(dg.data, allowMalformed: true);
      if (raw.trim().isEmpty) return;
      _messageCtl.add(SipMessage.parse(raw));
    } catch (_) {
      /* drop malformed datagram */
    }
  }
}
