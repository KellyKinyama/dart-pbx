/// Minimal RFC 3550 RTCP packet codec — pure Dart.
///
/// Implements just enough for an audio call:
///
///   * SR  (Sender Report,    PT=200)
///   * RR  (Receiver Report,  PT=201)
///   * SDES(Source Description PT=202) — CNAME only
///   * BYE (Goodbye,          PT=203)
///
/// Packets are length-prefixed in 32-bit words (`length = words - 1`) per
/// §6.4.1, and compound packets concatenate one report (SR/RR) followed by
/// SDES, terminated with BYE on shutdown (§6.1).
library;

import 'dart:typed_data';

const int rtcpVersion = 2;

const int rtcpPtSr = 200;
const int rtcpPtRr = 201;
const int rtcpPtSdes = 202;
const int rtcpPtBye = 203;

const int sdesCname = 1;

/// NTP epoch (1900-01-01) is 2208988800 seconds before the Unix epoch.
const int _ntpUnixOffsetSeconds = 2208988800;

/// One row of an SR/RR report block (§6.4.1).
class ReportBlock {
  const ReportBlock({
    required this.ssrc,
    required this.fractionLost,
    required this.cumulativeLost,
    required this.extendedHighestSeq,
    required this.jitter,
    required this.lastSr,
    required this.delaySinceLastSr,
  });

  /// SSRC of the source this block describes.
  final int ssrc;

  /// 8-bit fraction of packets lost since the previous SR/RR.
  final int fractionLost;

  /// 24-bit signed cumulative number of packets lost.
  final int cumulativeLost;

  /// Extended highest sequence number received (high 16 = cycles).
  final int extendedHighestSeq;

  /// Inter-arrival jitter, in RTP timestamp units.
  final int jitter;

  /// Middle 32 bits of the last SR's NTP timestamp (or 0).
  final int lastSr;

  /// Delay since last SR, in 1/65536 second units (or 0).
  final int delaySinceLastSr;

  Uint8List toBytes() {
    final b = Uint8List(24);
    final bd = ByteData.sublistView(b);
    bd.setUint32(0, ssrc & 0xFFFFFFFF);
    final flCl = ((fractionLost & 0xFF) << 24) | (cumulativeLost & 0x00FFFFFF);
    bd.setUint32(4, flCl);
    bd.setUint32(8, extendedHighestSeq & 0xFFFFFFFF);
    bd.setUint32(12, jitter & 0xFFFFFFFF);
    bd.setUint32(16, lastSr & 0xFFFFFFFF);
    bd.setUint32(20, delaySinceLastSr & 0xFFFFFFFF);
    return b;
  }

  static ReportBlock parse(ByteData bd, int offset) {
    final ssrc = bd.getUint32(offset);
    final flCl = bd.getUint32(offset + 4);
    final fl = (flCl >> 24) & 0xFF;
    var cl = flCl & 0x00FFFFFF;
    if ((cl & 0x00800000) != 0) cl |= 0xFF000000; // sign-extend 24→32
    return ReportBlock(
      ssrc: ssrc,
      fractionLost: fl,
      cumulativeLost: cl.toSigned(32),
      extendedHighestSeq: bd.getUint32(offset + 8),
      jitter: bd.getUint32(offset + 12),
      lastSr: bd.getUint32(offset + 16),
      delaySinceLastSr: bd.getUint32(offset + 20),
    );
  }
}

/// Sender Report (PT=200).
class SenderReport {
  const SenderReport({
    required this.ssrc,
    required this.ntpSeconds,
    required this.ntpFraction,
    required this.rtpTimestamp,
    required this.packetCount,
    required this.octetCount,
    this.reports = const <ReportBlock>[],
  });

  final int ssrc;
  final int ntpSeconds;
  final int ntpFraction;
  final int rtpTimestamp;
  final int packetCount;
  final int octetCount;
  final List<ReportBlock> reports;

  Uint8List toBytes() {
    final headerAndSender = 28; // 4 hdr + 24 sender info
    final blocks = reports.length;
    final total = headerAndSender + blocks * 24;
    assert(total % 4 == 0);

    final out = Uint8List(total);
    final bd = ByteData.sublistView(out);

    out[0] = (rtcpVersion << 6) | (blocks & 0x1F);
    out[1] = rtcpPtSr;
    final words = (total ~/ 4) - 1;
    bd.setUint16(2, words);

    bd.setUint32(4, ssrc & 0xFFFFFFFF);
    bd.setUint32(8, ntpSeconds & 0xFFFFFFFF);
    bd.setUint32(12, ntpFraction & 0xFFFFFFFF);
    bd.setUint32(16, rtpTimestamp & 0xFFFFFFFF);
    bd.setUint32(20, packetCount & 0xFFFFFFFF);
    bd.setUint32(24, octetCount & 0xFFFFFFFF);

    var offset = headerAndSender;
    for (final r in reports) {
      out.setRange(offset, offset + 24, r.toBytes());
      offset += 24;
    }
    return out;
  }

  static SenderReport parse(Uint8List data, int offset, int rc) {
    final bd = ByteData.sublistView(data);
    final reports = <ReportBlock>[];
    for (var i = 0; i < rc; i++) {
      reports.add(ReportBlock.parse(bd, offset + 28 + i * 24));
    }
    return SenderReport(
      ssrc: bd.getUint32(offset + 4),
      ntpSeconds: bd.getUint32(offset + 8),
      ntpFraction: bd.getUint32(offset + 12),
      rtpTimestamp: bd.getUint32(offset + 16),
      packetCount: bd.getUint32(offset + 20),
      octetCount: bd.getUint32(offset + 24),
      reports: reports,
    );
  }
}

/// Receiver Report (PT=201).
class ReceiverReport {
  const ReceiverReport({
    required this.ssrc,
    this.reports = const <ReportBlock>[],
  });

  final int ssrc;
  final List<ReportBlock> reports;

  Uint8List toBytes() {
    final blocks = reports.length;
    final total = 8 + blocks * 24;
    final out = Uint8List(total);
    final bd = ByteData.sublistView(out);

    out[0] = (rtcpVersion << 6) | (blocks & 0x1F);
    out[1] = rtcpPtRr;
    bd.setUint16(2, (total ~/ 4) - 1);
    bd.setUint32(4, ssrc & 0xFFFFFFFF);

    var offset = 8;
    for (final r in reports) {
      out.setRange(offset, offset + 24, r.toBytes());
      offset += 24;
    }
    return out;
  }

  static ReceiverReport parse(Uint8List data, int offset, int rc) {
    final bd = ByteData.sublistView(data);
    final reports = <ReportBlock>[];
    for (var i = 0; i < rc; i++) {
      reports.add(ReportBlock.parse(bd, offset + 8 + i * 24));
    }
    return ReceiverReport(ssrc: bd.getUint32(offset + 4), reports: reports);
  }
}

/// Single SDES chunk: an SSRC plus a list of items (we only emit CNAME).
class SdesChunk {
  const SdesChunk({required this.ssrc, required this.cname});
  final int ssrc;
  final String cname;
}

/// SDES packet (PT=202) carrying one chunk (CNAME).
class SourceDescription {
  const SourceDescription({required this.chunks});
  final List<SdesChunk> chunks;

  Uint8List toBytes() {
    // Each chunk: 4 (SSRC) + 2 (type+len) + cname bytes + 1 (END=0),
    // padded up to a 4-byte boundary.
    final chunkBytes = <Uint8List>[];
    for (final c in chunks) {
      final cnameBytes = Uint8List.fromList(c.cname.codeUnits);
      assert(cnameBytes.length <= 255, 'CNAME too long');
      var len = 4 + 2 + cnameBytes.length + 1;
      final pad = (4 - (len % 4)) % 4;
      final buf = Uint8List(len + pad);
      final bd = ByteData.sublistView(buf);
      bd.setUint32(0, c.ssrc & 0xFFFFFFFF);
      buf[4] = sdesCname;
      buf[5] = cnameBytes.length;
      buf.setRange(6, 6 + cnameBytes.length, cnameBytes);
      // buf[6 + cnameBytes.length] is the END (0) item, already zero.
      chunkBytes.add(buf);
    }
    final body = chunkBytes.fold<int>(0, (a, b) => a + b.length);
    final total = 4 + body;
    final out = Uint8List(total);
    final bd = ByteData.sublistView(out);
    out[0] = (rtcpVersion << 6) | (chunks.length & 0x1F);
    out[1] = rtcpPtSdes;
    bd.setUint16(2, (total ~/ 4) - 1);
    var offset = 4;
    for (final c in chunkBytes) {
      out.setRange(offset, offset + c.length, c);
      offset += c.length;
    }
    return out;
  }
}

/// BYE packet (PT=203).
class GoodBye {
  const GoodBye({required this.sources, this.reason});
  final List<int> sources;
  final String? reason;

  Uint8List toBytes() {
    final reasonBytes = reason == null
        ? null
        : Uint8List.fromList(reason!.codeUnits);
    var len = 4 + sources.length * 4;
    if (reasonBytes != null) {
      len += 1 + reasonBytes.length;
      final pad = (4 - (len % 4)) % 4;
      len += pad;
    }
    final out = Uint8List(len);
    final bd = ByteData.sublistView(out);
    out[0] = (rtcpVersion << 6) | (sources.length & 0x1F);
    out[1] = rtcpPtBye;
    bd.setUint16(2, (len ~/ 4) - 1);
    var off = 4;
    for (final s in sources) {
      bd.setUint32(off, s & 0xFFFFFFFF);
      off += 4;
    }
    if (reasonBytes != null) {
      out[off] = reasonBytes.length;
      out.setRange(off + 1, off + 1 + reasonBytes.length, reasonBytes);
    }
    return out;
  }
}

/// One element of a parsed compound RTCP datagram.
sealed class RtcpPacket {}

class RtcpSr extends RtcpPacket {
  RtcpSr(this.report);
  final SenderReport report;
}

class RtcpRr extends RtcpPacket {
  RtcpRr(this.report);
  final ReceiverReport report;
}

class RtcpSdes extends RtcpPacket {
  RtcpSdes(this.sdes);
  final SourceDescription sdes;
}

class RtcpBye extends RtcpPacket {
  RtcpBye(this.bye);
  final GoodBye bye;
}

class RtcpUnknown extends RtcpPacket {
  RtcpUnknown(this.payloadType);
  final int payloadType;
}

/// Parse a (possibly compound) RTCP datagram. Returns an empty list if the
/// buffer is malformed.
List<RtcpPacket> parseRtcp(Uint8List data) {
  final out = <RtcpPacket>[];
  var offset = 0;
  while (offset + 4 <= data.length) {
    final b0 = data[offset];
    final pt = data[offset + 1];
    if (((b0 >> 6) & 0x03) != rtcpVersion) return out;
    final rc = b0 & 0x1F;
    final words = (data[offset + 2] << 8) | data[offset + 3];
    final lengthBytes = (words + 1) * 4;
    if (offset + lengthBytes > data.length) return out;

    switch (pt) {
      case rtcpPtSr:
        out.add(RtcpSr(SenderReport.parse(data, offset, rc)));
        break;
      case rtcpPtRr:
        out.add(RtcpRr(ReceiverReport.parse(data, offset, rc)));
        break;
      case rtcpPtSdes:
        // We don't need to parse SDES chunks for telemetry; record presence.
        out.add(RtcpSdes(const SourceDescription(chunks: <SdesChunk>[])));
        break;
      case rtcpPtBye:
        final sources = <int>[];
        final bd = ByteData.sublistView(data);
        for (var i = 0; i < rc; i++) {
          sources.add(bd.getUint32(offset + 4 + i * 4));
        }
        out.add(RtcpBye(GoodBye(sources: sources)));
        break;
      default:
        out.add(RtcpUnknown(pt));
    }
    offset += lengthBytes;
  }
  return out;
}

/// Convert a Unix timestamp (microseconds) to NTP (seconds, fraction) for SR.
({int seconds, int fraction}) unixMicrosToNtp(int microsSinceEpoch) {
  final secs = microsSinceEpoch ~/ 1000000;
  final micros = microsSinceEpoch % 1000000;
  final ntpSec = (secs + _ntpUnixOffsetSeconds) & 0xFFFFFFFF;
  // fraction = micros * 2^32 / 1e6
  final frac = ((micros * 4294967296) ~/ 1000000) & 0xFFFFFFFF;
  return (seconds: ntpSec, fraction: frac);
}

/// Middle 32 bits of an NTP timestamp (used in SR and the LSR field of RR).
int ntpMiddle32(int ntpSeconds, int ntpFraction) {
  return (((ntpSeconds & 0xFFFF) << 16) | ((ntpFraction >> 16) & 0xFFFF)) &
      0xFFFFFFFF;
}
