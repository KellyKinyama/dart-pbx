/// Video media plane: RTP/RTCP transport for VP8 frames over RFC 7741.
///
/// Mirrors [`MediaSession`] (audio) but for video:
///
///   * Opens a UDP RTP socket and a paired RTCP socket (RFC 3550 §11).
///   * Accepts encoded video frames from a [VideoEncoder] and packetizes
///     them with [packetizeVp8] before sending.
///   * Reassembles inbound RTP fragments via [Vp8Depacketizer], hands the
///     resulting frame to a [VideoDecoder], and emits decoded [YuvFrame]s
///     on [incomingFrames].
///
/// Camera capture is NOT performed here — feed [pushEncoded] (for raw
/// bytestream mode) or [pushFrame] (with an encoder) from whatever
/// capture pipeline you have (e.g. the `camera` plugin, a file source,
/// a screen grabber).
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../audio/rtcp.dart';
import '../audio/rtp.dart';
import '../audio/rtp_stats.dart';
import '../sdp.dart';
import 'video_codec.dart';
import 'vp8_rtp.dart';

const int _videoClockRate = 90000;
const Duration _rtcpInterval = Duration(seconds: 5);

final Random _rng = Random.secure();

/// Negotiated remote video endpoint.
class VideoEndpoint {
  const VideoEndpoint({
    required this.host,
    required this.port,
    required this.payloadType,
    required this.codec,
    int? rtcpPort,
  }) : rtcpPort = rtcpPort ?? port + 1;

  final String host;
  final int port;
  final int rtcpPort;
  final int payloadType;
  final SdpVideoCodec codec;

  factory VideoEndpoint.fromSdp(SdpVideo s) => VideoEndpoint(
    host: s.host,
    port: s.port,
    payloadType: s.payloadType,
    codec: s.codec,
    rtcpPort: s.effectiveRtcpPort,
  );
}

class VideoSession {
  VideoSession({
    VideoEncoder? encoder,
    VideoDecoder? decoder,
    String? cname,
    int maxPayloadSize = defaultVp8MaxPayload,
  }) : _encoder = encoder,
       _decoder = decoder,
       _maxPayloadSize = maxPayloadSize,
       cname = cname ?? _defaultCname();

  final VideoEncoder? _encoder;
  final VideoDecoder? _decoder;
  final int _maxPayloadSize;
  final String cname;

  RawDatagramSocket? _socket;
  RawDatagramSocket? _rtcpSocket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  StreamSubscription<RawSocketEvent>? _rtcpSub;
  InternetAddress? _remoteAddr;
  InternetAddress? _remoteRtcpAddr;
  VideoEndpoint? _remote;
  RtpState? _state;
  Timer? _rtcpTimer;
  bool _symmetricLocked = false;
  int _rtpTimestamp = 0;

  final Vp8Depacketizer _depack = Vp8Depacketizer();
  final RtpStats stats = RtpStats();

  final _incomingCtl = StreamController<YuvFrame>.broadcast();
  final _incomingEncodedCtl = StreamController<Uint8List>.broadcast();

  /// Decoded frames coming off the wire. Empty if no [VideoDecoder] was
  /// configured.
  Stream<YuvFrame> get incomingFrames => _incomingCtl.stream;

  /// Raw reassembled compressed frames (post-depacketizer, pre-decoder).
  /// Useful when you want to forward, record or decode out-of-band.
  Stream<Uint8List> get incomingEncoded => _incomingEncodedCtl.stream;

  int get localPort => _socket?.port ?? 0;
  int get localRtcpPort => _rtcpSocket?.port ?? 0;

  static String _defaultCname() {
    final r = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return 'flutter_sip_ua-video-$r@local';
  }

  /// Open RTP + RTCP sockets, preferring an even RTP port whose +1 is free.
  Future<int> bindLocalPort({String bindAddress = '0.0.0.0'}) async {
    if (_socket != null) return _socket!.port;
    final addr = InternetAddress(bindAddress);

    RawDatagramSocket? rtp;
    RawDatagramSocket? rtcp;
    for (var i = 0; i < 8; i++) {
      final candidate = await RawDatagramSocket.bind(addr, 0);
      final port = candidate.port;
      if (port.isEven) {
        try {
          rtcp = await RawDatagramSocket.bind(addr, port + 1);
          rtp = candidate;
          break;
        } catch (_) {
          candidate.close();
          continue;
        }
      } else {
        candidate.close();
      }
    }
    rtp ??= await RawDatagramSocket.bind(addr, 0);
    rtcp ??= await RawDatagramSocket.bind(addr, 0);

    _socket = rtp;
    _rtcpSocket = rtcp;
    _socketSub = _socket!.listen(_onSocketEvent);
    _rtcpSub = _rtcpSocket!.listen(_onRtcpEvent);
    return _socket!.port;
  }

  /// Wire up the remote endpoint and start RTCP reporting. The first
  /// outbound frame must come via [pushFrame] / [pushEncoded].
  Future<void> start(VideoEndpoint remote) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('Call bindLocalPort() before start()');
    }
    _remote = remote;
    try {
      _remoteAddr = InternetAddress(remote.host);
    } catch (_) {
      final list = await InternetAddress.lookup(remote.host);
      if (list.isEmpty) {
        throw SocketException('Cannot resolve ${remote.host}');
      }
      _remoteAddr = list.first;
    }
    _remoteRtcpAddr = _remoteAddr;

    _state = RtpState(
      ssrc: DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF,
      payloadType: remote.payloadType,
    );
    _rtpTimestamp = DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF;

    _rtcpTimer?.cancel();
    final firstDelay = Duration(
      milliseconds: (_rtcpInterval.inMilliseconds * (0.5 + _rng.nextDouble()))
          .round(),
    );
    _rtcpTimer = Timer(firstDelay, () {
      _sendRtcpReport();
      _rtcpTimer = Timer.periodic(_rtcpInterval, (_) => _sendRtcpReport());
    });
  }

  /// Stop sending, close sockets, send RTCP BYE.
  Future<void> stop() async {
    _rtcpTimer?.cancel();
    _rtcpTimer = null;
    try {
      _sendRtcpBye();
    } catch (_) {}
    await _rtcpSub?.cancel();
    _rtcpSub = null;
    _rtcpSocket?.close();
    _rtcpSocket = null;
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
    _remote = null;
    _remoteAddr = null;
    _remoteRtcpAddr = null;
    _state = null;
    _symmetricLocked = false;
    _encoder?.close();
    _decoder?.close();
  }

  /// Encode and send a raw camera frame. Requires a [VideoEncoder].
  ///
  /// `tsIncrement90k` advances the RTP timestamp; for a typical 30 fps
  /// feed this is 3000 (90000 / 30).
  void pushFrame(
    YuvFrame frame, {
    bool forceKeyframe = false,
    int tsIncrement90k = 3000,
  }) {
    final encoder = _encoder;
    if (encoder == null) {
      throw StateError('No VideoEncoder configured on this VideoSession');
    }
    final encoded = encoder.encode(frame, forceKeyframe: forceKeyframe);
    for (final f in encoded) {
      _sendEncoded(f.bytes);
    }
    _rtpTimestamp = (_rtpTimestamp + tsIncrement90k) & 0xFFFFFFFF;
  }

  /// Send an already-encoded compressed frame (e.g. when piping VP8 from
  /// a file or another process). The session packetizes it with RFC 7741.
  void pushEncoded(Uint8List frame, {int tsIncrement90k = 3000}) {
    _sendEncoded(frame);
    _rtpTimestamp = (_rtpTimestamp + tsIncrement90k) & 0xFFFFFFFF;
  }

  void _sendEncoded(Uint8List frame) {
    final state = _state;
    final socket = _socket;
    final addr = _remoteAddr;
    final remote = _remote;
    if (state == null || socket == null || addr == null || remote == null) {
      return;
    }
    if (frame.isEmpty) return;
    final fragments = packetizeVp8(frame, maxPayloadSize: _maxPayloadSize);
    for (final f in fragments) {
      final pkt = makeRtpPacket(
        state,
        f.payload,
        _rtpTimestamp & 0xFFFFFFFF,
        marker: f.marker,
      );
      socket.send(pkt, addr, remote.port);
      stats.onSent(f.payload.length, _rtpTimestamp & 0xFFFFFFFF);
    }
  }

  // -------------------------------------------------------------------------
  // Receive
  // -------------------------------------------------------------------------

  void _onSocketEvent(RawSocketEvent ev) {
    if (ev != RawSocketEvent.read) return;
    final s = _socket;
    if (s == null) return;
    final dg = s.receive();
    if (dg == null) return;
    final pkt = parseRtp(dg.data);
    if (pkt == null) return;

    if (!_symmetricLocked) {
      _remoteAddr = dg.address;
      final r = _remote;
      if (r != null && dg.port != r.port) {
        _remote = VideoEndpoint(
          host: r.host,
          port: dg.port,
          payloadType: r.payloadType,
          codec: r.codec,
          rtcpPort: r.rtcpPort,
        );
      }
      _remoteRtcpAddr = dg.address;
      _symmetricLocked = true;
    }

    stats.onReceived(pkt, _videoClockRate);

    final assembled = _depack.add(
      payload: pkt.payload,
      marker: pkt.marker,
      timestamp: pkt.timestamp,
    );
    if (assembled == null) return;

    if (!_incomingEncodedCtl.isClosed) {
      _incomingEncodedCtl.add(assembled);
    }
    final decoder = _decoder;
    if (decoder != null) {
      try {
        final frame = decoder.decode(assembled);
        if (frame != null && !_incomingCtl.isClosed) {
          _incomingCtl.add(frame);
        }
      } catch (_) {
        // Decoder errors shouldn't kill the session.
      }
    }
  }

  void _onRtcpEvent(RawSocketEvent ev) {
    if (ev != RawSocketEvent.read) return;
    final s = _rtcpSocket;
    if (s == null) return;
    final dg = s.receive();
    if (dg == null) return;
    final packets = parseRtcp(dg.data);
    for (final p in packets) {
      if (p is RtcpSr) {
        final mid = ntpMiddle32(p.report.ntpSeconds, p.report.ntpFraction);
        stats.onSenderReport(mid);
      }
    }
  }

  // -------------------------------------------------------------------------
  // RTCP send
  // -------------------------------------------------------------------------

  int get _remoteRtcpPort => _remote?.rtcpPort ?? 0;

  void _sendRtcpReport() {
    final rtcp = _rtcpSocket;
    final addr = _remoteRtcpAddr ?? _remoteAddr;
    final state = _state;
    if (rtcp == null || addr == null || state == null) return;
    if (_remoteRtcpPort == 0) return;

    final ssrc = state.ssrc;
    final reports = <ReportBlock>[];
    if (stats.hasInbound && stats.remoteSsrc != null) {
      reports.add(
        ReportBlock(
          ssrc: stats.remoteSsrc!,
          fractionLost: stats.fractionLostSinceLastReport(),
          cumulativeLost: stats.cumulativeLost,
          extendedHighestSeq: stats.extendedHighestSeq,
          jitter: stats.jitter,
          lastSr: stats.lastSrMiddle32,
          delaySinceLastSr: stats.delaySinceLastSr,
        ),
      );
    }

    Uint8List head;
    if (stats.sentPackets > 0) {
      final ntp = unixMicrosToNtp(
        stats.lastSendUnixMicros == 0
            ? DateTime.now().microsecondsSinceEpoch
            : stats.lastSendUnixMicros,
      );
      head = SenderReport(
        ssrc: ssrc,
        ntpSeconds: ntp.seconds,
        ntpFraction: ntp.fraction,
        rtpTimestamp: stats.lastSentRtpTimestamp,
        packetCount: stats.sentPackets,
        octetCount: stats.sentOctets,
        reports: reports,
      ).toBytes();
    } else {
      head = ReceiverReport(ssrc: ssrc, reports: reports).toBytes();
    }

    final sdes = SourceDescription(
      chunks: [SdesChunk(ssrc: ssrc, cname: cname)],
    ).toBytes();
    final compound = Uint8List(head.length + sdes.length)
      ..setRange(0, head.length, head)
      ..setRange(head.length, head.length + sdes.length, sdes);
    rtcp.send(compound, addr, _remoteRtcpPort);
  }

  void _sendRtcpBye() {
    final rtcp = _rtcpSocket;
    final addr = _remoteRtcpAddr ?? _remoteAddr;
    final state = _state;
    if (rtcp == null || addr == null || state == null) return;
    if (_remoteRtcpPort == 0) return;
    final bye = GoodBye(sources: [state.ssrc]).toBytes();
    rtcp.send(bye, addr, _remoteRtcpPort);
  }
}
