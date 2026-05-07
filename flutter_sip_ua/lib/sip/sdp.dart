/// Tiny SDP helper — only what the SIP UA needs to negotiate G.711 audio
/// (and optional VP8 video) against dart-pbx. Not a full RFC 4566 parser.
library;

import 'audio/media_session.dart';

/// Direction attribute (RFC 4566 §6).
enum SdpDirection { sendrecv, sendonly, recvonly, inactive }

class SdpAudio {
  const SdpAudio({
    required this.host,
    required this.port,
    required this.codec,
    this.rtcpPort,
    this.direction = SdpDirection.sendrecv,
    this.telephoneEventPt,
  });

  /// Connection address from `c=`.
  final String host;

  /// RTP port from `m=audio <port>`.
  final int port;

  /// Negotiated G.711 variant.
  final G711Variant codec;

  /// Explicit RTCP port from `a=rtcp:<port>`. Null means RFC 3550 default
  /// (`port + 1`).
  final int? rtcpPort;

  /// Direction (`a=sendrecv` etc.). Defaults to `sendrecv` when absent.
  final SdpDirection direction;

  /// Payload type for `telephone-event` if the peer offered RFC 4733 DTMF.
  final int? telephoneEventPt;

  /// Effective RTCP port (explicit if signalled, otherwise port + 1).
  int get effectiveRtcpPort => rtcpPort ?? (port + 1);

  RtpEndpoint toEndpoint() => RtpEndpoint(
    host: host,
    port: port,
    codec: codec,
    rtcpPort: effectiveRtcpPort,
    telephoneEventPt: telephoneEventPt,
  );
}

/// Build a minimal SDP offer/answer for a G.711 audio session.
///
/// Also advertises RFC 4733 `telephone-event` (DTMF) on PT 101 by default.
String buildG711Offer({
  required String username,
  required String localHost,
  required int localPort,
  G711Variant preferred = G711Variant.pcmu,
  G711Variant? second = G711Variant.pcma,
  int? rtcpPort,
  int? telephoneEventPt = 101,
  SdpDirection direction = SdpDirection.sendrecv,
}) {
  final sessionId = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final pts = <G711Variant>[
    preferred,
    if (second != null && second != preferred) second,
  ];
  final ptNumbers = pts.map((v) => v.payloadType).toList();
  if (telephoneEventPt != null) ptNumbers.add(telephoneEventPt);
  final ptList = ptNumbers.join(' ');

  final lines = <String>[
    'v=0',
    'o=$username $sessionId $sessionId IN IP4 $localHost',
    's=flutter_sip_ua',
    'c=IN IP4 $localHost',
    't=0 0',
    'm=audio $localPort RTP/AVP $ptList',
    for (final v in pts) 'a=rtpmap:${v.payloadType} ${v.rtpmap}/8000',
    if (telephoneEventPt != null) ...[
      'a=rtpmap:$telephoneEventPt telephone-event/8000',
      'a=fmtp:$telephoneEventPt 0-15',
    ],
    if (rtcpPort != null) 'a=rtcp:$rtcpPort',
    'a=ptime:20',
    'a=${_directionToken(direction)}',
  ];
  return '${lines.join('\r\n')}\r\n';
}

String _directionToken(SdpDirection d) {
  switch (d) {
    case SdpDirection.sendrecv:
      return 'sendrecv';
    case SdpDirection.sendonly:
      return 'sendonly';
    case SdpDirection.recvonly:
      return 'recvonly';
    case SdpDirection.inactive:
      return 'inactive';
  }
}

/// Parse the remote audio endpoint from an SDP body. Returns null if the
/// body has no audio media line we can use.
SdpAudio? parseSdpAudio(String sdp) {
  if (sdp.trim().isEmpty) return null;
  String? sessionConn;
  String? mediaConn;
  String? mLine;
  int? rtcpPort;
  SdpDirection? direction;
  int? telephoneEventPt;
  // Track which payload types appear in m= and any rtpmap entries so we
  // can pick PCMU (0) or PCMA (8) deterministically.
  final ptInMedia = <int>[];
  final rtpmapNames = <int, String>{};

  var inAudio = false;
  for (final raw in sdp.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('c=') && !inAudio) {
      sessionConn = line;
    } else if (line.startsWith('m=')) {
      inAudio = line.startsWith('m=audio');
      if (inAudio) {
        mLine = line;
        // m=audio <port> RTP/AVP <pt> <pt> ...
        final parts = line.split(RegExp(r'\s+'));
        for (var i = 3; i < parts.length; i++) {
          final pt = int.tryParse(parts[i]);
          if (pt != null) ptInMedia.add(pt);
        }
      }
    } else if (inAudio && line.startsWith('c=')) {
      mediaConn = line;
    } else if (inAudio && line.startsWith('a=rtpmap:')) {
      // a=rtpmap:<pt> <name>/<rate>[/channels]
      final rest = line.substring('a=rtpmap:'.length);
      final sp = rest.indexOf(' ');
      if (sp > 0) {
        final pt = int.tryParse(rest.substring(0, sp));
        if (pt != null) {
          final name = rest.substring(sp + 1).split('/').first.toUpperCase();
          rtpmapNames[pt] = name;
          if (name == 'TELEPHONE-EVENT') telephoneEventPt = pt;
        }
      }
    } else if (inAudio && line.startsWith('a=rtcp:')) {
      // a=rtcp:<port> [<nettype> <addrtype> <addr>]
      final rest = line.substring('a=rtcp:'.length).trim();
      final tok = rest.split(RegExp(r'\s+')).first;
      rtcpPort = int.tryParse(tok);
    } else if (inAudio) {
      switch (line) {
        case 'a=sendrecv':
          direction = SdpDirection.sendrecv;
          break;
        case 'a=sendonly':
          direction = SdpDirection.sendonly;
          break;
        case 'a=recvonly':
          direction = SdpDirection.recvonly;
          break;
        case 'a=inactive':
          direction = SdpDirection.inactive;
          break;
      }
    }
  }

  if (mLine == null) return null;
  final mParts = mLine.split(RegExp(r'\s+'));
  if (mParts.length < 4) return null;
  final port = int.tryParse(mParts[1]);
  if (port == null || port == 0) return null;

  final connLine = mediaConn ?? sessionConn;
  if (connLine == null) return null;
  // c=IN IP4 <host>
  final cParts = connLine.split(RegExp(r'\s+'));
  if (cParts.length < 3) return null;
  final host = cParts[2];

  // Pick first PT we know about (prefer PCMU then PCMA).
  G711Variant? chosen;
  for (final pt in ptInMedia) {
    final variant = G711Variant.fromPayloadType(pt);
    if (variant != null) {
      chosen = variant;
      break;
    }
  }
  // Fall back to rtpmap-by-name if the static PTs weren't 0/8.
  if (chosen == null) {
    for (final entry in rtpmapNames.entries) {
      if (entry.value == 'PCMU') {
        chosen = G711Variant.pcmu;
        break;
      }
      if (entry.value == 'PCMA') {
        chosen = G711Variant.pcma;
        break;
      }
    }
  }
  if (chosen == null) return null;

  return SdpAudio(
    host: host,
    port: port,
    codec: chosen,
    rtcpPort: rtcpPort,
    direction: direction ?? SdpDirection.sendrecv,
    telephoneEventPt: telephoneEventPt,
  );
}

// ---------------------------------------------------------------------------
// Video (VP8 over RTP, RFC 7741)
// ---------------------------------------------------------------------------

/// Video codecs we understand for SDP negotiation.
enum SdpVideoCodec {
  vp8('VP8', 90000),
  vp9('VP9', 90000),
  h264('H264', 90000);

  const SdpVideoCodec(this.rtpmap, this.clockRate);
  final String rtpmap;
  final int clockRate;
}

class SdpVideo {
  const SdpVideo({
    required this.host,
    required this.port,
    required this.payloadType,
    required this.codec,
    this.rtcpPort,
    this.direction = SdpDirection.sendrecv,
  });

  final String host;
  final int port;

  /// Dynamic RTP payload type (96..127) negotiated for this codec.
  final int payloadType;

  final SdpVideoCodec codec;
  final int? rtcpPort;
  final SdpDirection direction;

  int get effectiveRtcpPort => rtcpPort ?? (port + 1);
}

/// Bundle returned by [parseSdp] — either or both media sections may be null.
class SdpOffer {
  const SdpOffer({this.audio, this.video});
  final SdpAudio? audio;
  final SdpVideo? video;
}

/// Build an audio+video SDP offer/answer. Audio uses the same defaults as
/// [buildG711Offer]; video advertises VP8 on PT 96 by default.
String buildAvOffer({
  required String username,
  required String localHost,
  required int audioPort,
  int? videoPort,
  G711Variant audioPreferred = G711Variant.pcmu,
  G711Variant? audioSecond = G711Variant.pcma,
  int? audioRtcpPort,
  int? telephoneEventPt = 101,
  int videoPayloadType = 96,
  SdpVideoCodec videoCodec = SdpVideoCodec.vp8,
  int? videoRtcpPort,
  SdpDirection direction = SdpDirection.sendrecv,
}) {
  final sessionId = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final audioPts = <G711Variant>[
    audioPreferred,
    if (audioSecond != null && audioSecond != audioPreferred) audioSecond,
  ];
  final audioPtNumbers = audioPts.map((v) => v.payloadType).toList();
  if (telephoneEventPt != null) audioPtNumbers.add(telephoneEventPt);

  final lines = <String>[
    'v=0',
    'o=$username $sessionId $sessionId IN IP4 $localHost',
    's=flutter_sip_ua',
    'c=IN IP4 $localHost',
    't=0 0',
    'm=audio $audioPort RTP/AVP ${audioPtNumbers.join(' ')}',
    for (final v in audioPts) 'a=rtpmap:${v.payloadType} ${v.rtpmap}/8000',
    if (telephoneEventPt != null) ...[
      'a=rtpmap:$telephoneEventPt telephone-event/8000',
      'a=fmtp:$telephoneEventPt 0-15',
    ],
    if (audioRtcpPort != null) 'a=rtcp:$audioRtcpPort',
    'a=ptime:20',
    'a=${_directionToken(direction)}',
    if (videoPort != null) ...[
      'm=video $videoPort RTP/AVP $videoPayloadType',
      'a=rtpmap:$videoPayloadType ${videoCodec.rtpmap}/${videoCodec.clockRate}',
      if (videoRtcpPort != null) 'a=rtcp:$videoRtcpPort',
      'a=${_directionToken(direction)}',
    ],
  ];
  return '${lines.join('\r\n')}\r\n';
}

/// Parse a full SDP body into its audio + optional video section. Reuses
/// [parseSdpAudio] internally for the audio half so all the existing code
/// paths keep working.
SdpOffer parseSdp(String sdp) {
  final audio = parseSdpAudio(sdp);
  final video = _parseSdpVideo(sdp);
  return SdpOffer(audio: audio, video: video);
}

SdpVideo? _parseSdpVideo(String sdp) {
  if (sdp.trim().isEmpty) return null;
  String? sessionConn;
  String? mediaConn;
  String? mLine;
  int? rtcpPort;
  SdpDirection? direction;
  final ptInMedia = <int>[];
  final rtpmapNames = <int, String>{};

  var inVideo = false;
  for (final raw in sdp.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('c=') && !inVideo && sessionConn == null) {
      sessionConn = line;
    } else if (line.startsWith('m=')) {
      inVideo = line.startsWith('m=video');
      if (inVideo) {
        mLine = line;
        final parts = line.split(RegExp(r'\s+'));
        for (var i = 3; i < parts.length; i++) {
          final pt = int.tryParse(parts[i]);
          if (pt != null) ptInMedia.add(pt);
        }
      }
    } else if (inVideo && line.startsWith('c=')) {
      mediaConn = line;
    } else if (inVideo && line.startsWith('a=rtpmap:')) {
      final rest = line.substring('a=rtpmap:'.length);
      final sp = rest.indexOf(' ');
      if (sp > 0) {
        final pt = int.tryParse(rest.substring(0, sp));
        if (pt != null) {
          rtpmapNames[pt] = rest
              .substring(sp + 1)
              .split('/')
              .first
              .toUpperCase();
        }
      }
    } else if (inVideo && line.startsWith('a=rtcp:')) {
      final rest = line.substring('a=rtcp:'.length).trim();
      rtcpPort = int.tryParse(rest.split(RegExp(r'\s+')).first);
    } else if (inVideo) {
      switch (line) {
        case 'a=sendrecv':
          direction = SdpDirection.sendrecv;
          break;
        case 'a=sendonly':
          direction = SdpDirection.sendonly;
          break;
        case 'a=recvonly':
          direction = SdpDirection.recvonly;
          break;
        case 'a=inactive':
          direction = SdpDirection.inactive;
          break;
      }
    }
  }

  if (mLine == null) return null;
  final mParts = mLine.split(RegExp(r'\s+'));
  if (mParts.length < 4) return null;
  final port = int.tryParse(mParts[1]);
  if (port == null || port == 0) return null;

  final connLine = mediaConn ?? sessionConn;
  if (connLine == null) return null;
  final cParts = connLine.split(RegExp(r'\s+'));
  if (cParts.length < 3) return null;
  final host = cParts[2];

  // Pick the first PT whose rtpmap names a codec we recognise.
  int? chosenPt;
  SdpVideoCodec? chosenCodec;
  for (final pt in ptInMedia) {
    final name = rtpmapNames[pt];
    if (name == null) continue;
    for (final codec in SdpVideoCodec.values) {
      if (codec.rtpmap == name) {
        chosenPt = pt;
        chosenCodec = codec;
        break;
      }
    }
    if (chosenCodec != null) break;
  }
  if (chosenPt == null || chosenCodec == null) return null;

  return SdpVideo(
    host: host,
    port: port,
    payloadType: chosenPt,
    codec: chosenCodec,
    rtcpPort: rtcpPort,
    direction: direction ?? SdpDirection.sendrecv,
  );
}
