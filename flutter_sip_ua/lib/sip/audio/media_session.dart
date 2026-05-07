/// Media plane for SIP calls.
///
/// * Opens a UDP socket on an ephemeral local port (the RTP port that goes
///   into our SDP offer/answer).
/// * Captures microphone audio via `mic_stream` (16-bit signed PCM).
/// * Down-samples to 8 kHz mono if the device gave us a higher rate.
/// * Encodes 20 ms frames (160 samples) with G.711 (μ-law or A-law).
/// * Builds RTP packets via `rtp.dart` and sends them to the remote
///   IP/port learned from the peer's SDP.
/// * Receives RTP and exposes a stream of decoded Int16 PCM frames so a
///   future playback engine can render them. Playback itself is out of
///   scope for this signalling-first UA — wire `incomingPcm` into your
///   audio sink of choice (audio_streamer, flutter_pcm_sound, ...).
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mic_stream/mic_stream.dart';
import 'package:permission_handler/permission_handler.dart';

import 'audio_sink.dart';
import 'g711.dart';
import 'jitter_buffer.dart';
import 'rtcp.dart';
import 'rtp.dart';
import 'rtp_stats.dart';

/// G.711 codec selection.
enum G711Variant {
  pcmu(0, 'PCMU'),
  pcma(8, 'PCMA');

  const G711Variant(this.payloadType, this.rtpmap);
  final int payloadType;
  final String rtpmap;

  static G711Variant? fromPayloadType(int pt) {
    for (final v in values) {
      if (v.payloadType == pt) return v;
    }
    return null;
  }
}

/// Negotiated remote media endpoint (parsed from SDP).
class RtpEndpoint {
  const RtpEndpoint({
    required this.host,
    required this.port,
    required this.codec,
    int? rtcpPort,
    this.telephoneEventPt,
  }) : rtcpPort = rtcpPort ?? port + 1;

  final String host;
  final int port;

  /// Where to send RTCP. Defaults to `port + 1` per RFC 3550 §11.
  final int rtcpPort;
  final G711Variant codec;

  /// PT to use for RFC 4733 DTMF, if the peer offered it.
  final int? telephoneEventPt;
}

/// 20 ms RTP packetisation at 8 kHz = 160 samples per frame.
const int _g711FrameSamples = 160;
const int _g711ClockRate = 8000;

/// Default RTCP report interval. RFC 3550 §6.2 suggests dynamic intervals
/// based on session bandwidth; for a unicast 2-party G.711 call a fixed
/// 5 s cadence is well within the recommended bounds.
const Duration _rtcpInterval = Duration(seconds: 5);

/// RFC 4733 DTMF events use a 4-byte payload (event, end+volume, duration).
const int _dtmfPayloadBytes = 4;
const int _dtmfTickSamples = 160; // one G.711 frame == 20 ms

final Random _rng = Random.secure();

class MediaSession {
  MediaSession({
    String? cname,
    AudioSink? sink,
    int jitterTargetFrames = 3,
    int jitterMaxFrames = 12,
  }) : cname = cname ?? _defaultCname(),
       _sink = sink ?? const NullAudioSink(),
       _jitterTargetFrames = jitterTargetFrames,
       _jitterMaxFrames = jitterMaxFrames;

  /// CNAME advertised in SDES. Stable for the life of this session.
  final String cname;

  RawDatagramSocket? _socket;
  RawDatagramSocket? _rtcpSocket;
  StreamSubscription<RawSocketEvent>? _rtcpSub;
  InternetAddress? _remoteAddr;
  InternetAddress? _remoteRtcpAddr;
  RtpEndpoint? _remote;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<RawSocketEvent>? _socketSub;
  RtpState? _state;
  G711Variant _codec = G711Variant.pcmu;
  int _rtpTimestamp = 0;
  int _captureSampleRate = 8000;
  Timer? _rtcpTimer;

  /// True once we've locked the remote RTP source/port from the first
  /// inbound packet (symmetric RTP, RFC 4961).
  bool _symmetricLocked = false;

  /// Stats used to populate SR/RR.
  final RtpStats stats = RtpStats();

  /// When true, mic input is dropped before RTP encoding (audio still
  /// flows in the receive direction).
  bool muted = false;

  /// Where decoded inbound PCM goes for playback. The default sink is a
  /// no-op so the signalling-only behaviour is preserved unless the host
  /// app provides a real one.
  final AudioSink _sink;
  AudioSink get sink => _sink;

  final int _jitterTargetFrames;
  final int _jitterMaxFrames;
  JitterBuffer? _jitter;
  Timer? _jitterTick;

  /// Diagnostic snapshot of the current playout buffer.
  ({int buffered, int played, int lateDrops, int overflowDrops})
  get jitterStats {
    final j = _jitter;
    return (
      buffered: j?.length ?? 0,
      played: j?.playedFrames ?? 0,
      lateDrops: j?.lateDrops ?? 0,
      overflowDrops: j?.overflowDrops ?? 0,
    );
  }

  static String _defaultCname() {
    final r = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return 'flutter_sip_ua-$r@local';
  }

  /// Buffer of accumulated mic samples (Int16) waiting to fill a 160-sample
  /// G.711 frame after downsampling.
  final List<int> _pcmAccum = <int>[];

  /// Stream of decoded inbound PCM frames (8 kHz, mono, signed 16-bit).
  final _incomingPcmCtl = StreamController<Int16List>.broadcast();
  Stream<Int16List> get incomingPcm => _incomingPcmCtl.stream;

  /// Local RTP port to advertise in SDP. Available after [bindLocalPort].
  int get localPort => _socket?.port ?? 0;

  /// Local RTCP port. By RFC 3550 convention this is `localPort + 1`.
  int get localRtcpPort => _rtcpSocket?.port ?? 0;

  /// Bind RTP + RTCP sockets and return the RTP port. RTCP is bound on the
  /// next odd port if available; otherwise on whatever port the OS gives.
  Future<int> bindLocalPort({String bindAddress = '0.0.0.0'}) async {
    if (_socket != null) return _socket!.port;
    final addr = InternetAddress(bindAddress);

    // Try to grab an even RTP port whose +1 is free, retrying a handful
    // of times before falling back to whatever the OS hands us.
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

  /// Wire up the remote endpoint and start sending RTP from the mic.
  ///
  /// Requires [bindLocalPort] to have been called first. Requests
  /// microphone permission on Android/iOS.
  Future<void> start(RtpEndpoint remote) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('Call bindLocalPort() before start()');
    }
    _remote = remote;
    _codec = remote.codec;
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
      payloadType: _codec.payloadType,
    );
    _rtpTimestamp = DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF;

    // Spin up the playout buffer. Even with a NullAudioSink this gives
    // useful diagnostics via [jitterStats].
    _jitter = JitterBuffer(
      sink: _sink,
      targetFrames: _jitterTargetFrames,
      maxFrames: _jitterMaxFrames,
    );
    // Pump the clock at the packetisation interval so playback continues
    // through brief network gaps.
    _jitterTick = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => _jitter?.tick(),
    );

    // Permission gate.
    final granted = await Permission.microphone.request();
    if (!granted.isGranted) {
      throw StateError('Microphone permission denied');
    }

    // Try to capture at 8 kHz directly; if the platform forces another
    // rate we'll downsample on the fly.
    final stream = MicStream.microphone(
      audioSource: AudioSource.DEFAULT,
      sampleRate: _g711ClockRate,
      channelConfig: ChannelConfig.CHANNEL_IN_MONO,
      audioFormat: AudioFormat.ENCODING_PCM_16BIT,
    );
    final actualRate = await MicStream.sampleRate;
    _captureSampleRate = actualRate.toInt();
    _micSub = stream.listen(_onMicChunk, onError: (_) {});

    // Schedule RTCP. Per RFC 3550 §6.3.2 the initial transmission is
    // randomized to half the deterministic interval so multiple endpoints
    // joining simultaneously don't synchronise their reports.
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

  /// Stop mic capture and close the RTP/RTCP sockets, sending RTCP BYE.
  Future<void> stop() async {
    _rtcpTimer?.cancel();
    _rtcpTimer = null;
    _jitterTick?.cancel();
    _jitterTick = null;
    final jitter = _jitter;
    _jitter = null;
    if (jitter != null) {
      await jitter.close();
    }
    await _micSub?.cancel();
    _micSub = null;

    // Best-effort BYE before tearing down RTCP.
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
    _remoteAddr = null;
    _remoteRtcpAddr = null;
    _remote = null;
    _state = null;
    _symmetricLocked = false;
    _pcmAccum.clear();
  }

  // ---------------------------------------------------------------------------
  // Mic → G.711 → RTP
  // ---------------------------------------------------------------------------

  void _onMicChunk(Uint8List bytes) {
    if (bytes.isEmpty) return;
    final samples = _bytesToInt16(bytes);
    final downsampled = _captureSampleRate == _g711ClockRate
        ? samples
        : _downsample(samples, _captureSampleRate, _g711ClockRate);

    _pcmAccum.addAll(downsampled);

    while (_pcmAccum.length >= _g711FrameSamples) {
      final frame = Int16List.fromList(_pcmAccum.sublist(0, _g711FrameSamples));
      _pcmAccum.removeRange(0, _g711FrameSamples);
      _emitFrame(frame);
    }
  }

  void _emitFrame(Int16List pcm) {
    if (muted) return;
    final payload = _codec == G711Variant.pcmu
        ? G711.encodeUlaw(pcm)
        : G711.encodeAlaw(pcm);

    final state = _state;
    final socket = _socket;
    final addr = _remoteAddr;
    final remote = _remote;
    if (state == null || socket == null || addr == null || remote == null) {
      return;
    }
    final pkt = makeRtpPacket(state, payload, _rtpTimestamp & 0xFFFFFFFF);
    socket.send(pkt, addr, remote.port);
    stats.onSent(payload.length, _rtpTimestamp & 0xFFFFFFFF);
    _rtpTimestamp = (_rtpTimestamp + _g711FrameSamples) & 0xFFFFFFFF;
  }

  // ---------------------------------------------------------------------------
  // RTP receive
  // ---------------------------------------------------------------------------

  void _onSocketEvent(RawSocketEvent ev) {
    if (ev != RawSocketEvent.read) return;
    final s = _socket;
    if (s == null) return;
    final dg = s.receive();
    if (dg == null) return;
    final pkt = parseRtp(dg.data);
    if (pkt == null) return;

    // Symmetric RTP: snap onto the actual source address/port observed for
    // the first valid inbound packet so NATs that rewrite the public port
    // are handled transparently (RFC 4961).
    if (!_symmetricLocked) {
      _remoteAddr = dg.address;
      final r = _remote;
      if (r != null && dg.port != r.port) {
        _remote = RtpEndpoint(
          host: r.host,
          port: dg.port,
          codec: r.codec,
          rtcpPort: r.rtcpPort,
          telephoneEventPt: r.telephoneEventPt,
        );
      }
      _remoteRtcpAddr = dg.address;
      _symmetricLocked = true;
    }

    stats.onReceived(pkt, _g711ClockRate);
    final variant = G711Variant.fromPayloadType(pkt.payloadType);
    if (variant == null) return; // ignore non-G.711 (e.g. DTMF telephone-event)
    final pcm = variant == G711Variant.pcmu
        ? G711.decodeUlaw(pkt.payload)
        : G711.decodeAlaw(pkt.payload);
    if (!_incomingPcmCtl.isClosed) {
      _incomingPcmCtl.add(pcm);
    }
    _jitter?.push(
      pkt.sequenceNumber,
      PcmFrame(pcm: pcm, sampleRate: _g711ClockRate, timestamp: pkt.timestamp),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Treat raw little-endian PCM bytes from `mic_stream` as Int16.
  static Int16List _bytesToInt16(Uint8List bytes) {
    final n = bytes.length & ~1; // drop trailing odd byte if any
    final out = Int16List(n ~/ 2);
    final bd = ByteData.sublistView(bytes, 0, n);
    for (var i = 0, j = 0; i < n; i += 2, j++) {
      out[j] = bd.getInt16(i, Endian.little);
    }
    return out;
  }

  /// Crude linear-interpolation downsampler (e.g. 16k/44.1k → 8k). Adequate
  /// for narrowband G.711 telephony; replace with a proper polyphase filter
  /// if you need higher fidelity.
  static List<int> _downsample(List<int> input, int srcRate, int dstRate) {
    if (srcRate == dstRate || input.isEmpty) return input;
    final ratio = srcRate / dstRate;
    final outLen = (input.length / ratio).floor();
    final out = List<int>.filled(outLen, 0);
    for (var i = 0; i < outLen; i++) {
      final srcIdx = i * ratio;
      final i0 = srcIdx.floor();
      final i1 = (i0 + 1).clamp(0, input.length - 1);
      final t = srcIdx - i0;
      final v = (input[i0] * (1 - t) + input[i1] * t).round();
      out[i] = v.clamp(-32768, 32767);
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // RTCP
  // ---------------------------------------------------------------------------

  /// RTCP port the peer is listening on. Either taken from SDP `a=rtcp:`,
  /// or RFC 3550 §11's default of `port + 1`.
  int get _remoteRtcpPort => _remote?.rtcpPort ?? 0;

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
      // RR / SDES / BYE are accepted silently; remote BYE means the peer
      // is tearing the call down — the SIP layer's BYE will handle the
      // session lifecycle, so no action needed here.
    }
  }

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

  // ---------------------------------------------------------------------------
  // RFC 4733 DTMF (telephone-event)
  // ---------------------------------------------------------------------------

  /// Send a DTMF digit to the peer if RFC 4733 was negotiated. The digit is
  /// streamed as `(duration / 20ms)` packets with the marker bit set on the
  /// first packet, then 3 end-of-event packets per RFC 4733 §2.5.1.3.
  ///
  /// `digit` accepts 0–9, *, #, and A–D. Throws [ArgumentError] otherwise.
  /// Silently no-ops if media isn't running or the peer didn't offer DTMF.
  Future<void> sendDtmf(
    String digit, {
    Duration duration = const Duration(milliseconds: 200),
    int volume = 10,
  }) async {
    final state = _state;
    final socket = _socket;
    final addr = _remoteAddr;
    final remote = _remote;
    if (state == null || socket == null || addr == null || remote == null) {
      return;
    }
    final pt = remote.telephoneEventPt;
    if (pt == null) return;

    final event = _dtmfEvent(digit);
    final totalSamples = (duration.inMilliseconds * _g711ClockRate ~/ 1000)
        .clamp(_dtmfTickSamples, 0xFFFF);
    final ticks = totalSamples ~/ _dtmfTickSamples;
    if (ticks <= 0) return;

    // Pre-allocate a separate sender state for DTMF so its sequence numbers
    // share the audio SSRC but we don't disturb audio packetisation.
    final dtmfState = RtpState(
      ssrc: state.ssrc,
      payloadType: pt,
      initialSequenceNumber: state.seq,
    );
    final startTs = _rtpTimestamp & 0xFFFFFFFF;

    for (var i = 1; i <= ticks; i++) {
      final samples = (i * _dtmfTickSamples).clamp(0, 0xFFFF);
      final marker = i == 1;
      final payload = _buildDtmfPayload(
        event: event,
        end: false,
        volume: volume,
        durationSamples: samples,
      );
      final pkt = makeRtpPacket(dtmfState, payload, startTs, marker: marker);
      socket.send(pkt, addr, remote.port);
      // The payload type doesn't carry octet-counted audio, so don't
      // advance the audio RTP timestamp here.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    // Three identical end packets for redundancy (§2.5.1.3).
    final endPayload = _buildDtmfPayload(
      event: event,
      end: true,
      volume: volume,
      durationSamples: (ticks * _dtmfTickSamples).clamp(0, 0xFFFF),
    );
    for (var i = 0; i < 3; i++) {
      final pkt = makeRtpPacket(dtmfState, endPayload, startTs);
      socket.send(pkt, addr, remote.port);
    }

    // Sync the audio sequence forward past the DTMF packets.
    state.seq = dtmfState.seq;
    // Advance audio timestamp by the DTMF duration so the next voice frame
    // lines up on the receiver's playout buffer.
    _rtpTimestamp = (_rtpTimestamp + ticks * _dtmfTickSamples) & 0xFFFFFFFF;
  }

  static int _dtmfEvent(String digit) {
    switch (digit) {
      case '0':
        return 0;
      case '1':
        return 1;
      case '2':
        return 2;
      case '3':
        return 3;
      case '4':
        return 4;
      case '5':
        return 5;
      case '6':
        return 6;
      case '7':
        return 7;
      case '8':
        return 8;
      case '9':
        return 9;
      case '*':
        return 10;
      case '#':
        return 11;
      case 'A':
      case 'a':
        return 12;
      case 'B':
      case 'b':
        return 13;
      case 'C':
      case 'c':
        return 14;
      case 'D':
      case 'd':
        return 15;
    }
    throw ArgumentError.value(digit, 'digit', 'Not a DTMF digit');
  }

  static Uint8List _buildDtmfPayload({
    required int event,
    required bool end,
    required int volume,
    required int durationSamples,
  }) {
    final out = Uint8List(_dtmfPayloadBytes);
    out[0] = event & 0xFF;
    // E (1 bit) | R (1 bit, MUST be 0) | volume (6 bits, dBm0).
    out[1] = (end ? 0x80 : 0x00) | (volume & 0x3F);
    out[2] = (durationSamples >> 8) & 0xFF;
    out[3] = durationSamples & 0xFF;
    return out;
  }
}
