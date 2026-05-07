/// RTP send/receive bookkeeping needed to emit RFC 3550 SR/RR reports.
library;

import 'rtp.dart';

/// Per-session sender + receiver statistics.
///
/// All counters use the algorithms described in RFC 3550:
///   * Receiver loss + cycles per Appendix A.3 (`update_seq`)
///   * Inter-arrival jitter per §6.4.1 / Appendix A.8
class RtpStats {
  RtpStats();

  // ---- Sender side --------------------------------------------------------
  int sentPackets = 0;
  int sentOctets = 0;

  /// Wall-clock micros at last sent packet — used to fill the SR timestamp.
  int lastSendUnixMicros = 0;

  /// RTP timestamp of the last packet we sent (mirrors what's on the wire).
  int lastSentRtpTimestamp = 0;

  void onSent(int payloadBytes, int rtpTimestamp) {
    sentPackets++;
    sentOctets += payloadBytes;
    lastSentRtpTimestamp = rtpTimestamp;
    lastSendUnixMicros = DateTime.now().microsecondsSinceEpoch;
  }

  // ---- Receiver side ------------------------------------------------------
  int? remoteSsrc;
  int _baseSeq = 0;
  int _maxSeq = 0;
  int _cycles = 0;
  int _received = 0;
  int _expectedPrior = 0;
  int _receivedPrior = 0;
  int _badSeq = -1;
  bool _probation = true;
  int _probationCount = 2; // RFC 3550 MIN_SEQUENTIAL = 2

  // Jitter (Appendix A.8).
  int _transit = 0;
  double _jitter = 0;
  bool _haveTransit = false;

  // For LSR / DLSR (§6.4.1).
  int _lastSrMiddle32 = 0;
  int _lastSrArrivalUnixMicros = 0;

  /// Inter-arrival jitter rounded to integer RTP units.
  int get jitter => _jitter.round();

  int get extendedHighestSeq => ((_cycles & 0xFFFF) << 16) | (_maxSeq & 0xFFFF);

  /// Cumulative packets lost (24-bit signed wrap is the caller's problem).
  int get cumulativeLost {
    final extendedMax = extendedHighestSeq;
    final expected = extendedMax - _baseSeq + 1;
    return expected - _received;
  }

  /// Fraction lost since the previous report (8-bit fixed point).
  int fractionLostSinceLastReport() {
    final extendedMax = extendedHighestSeq;
    final expected = extendedMax - _baseSeq + 1;
    final expectedInterval = expected - _expectedPrior;
    final receivedInterval = _received - _receivedPrior;
    final lostInterval = expectedInterval - receivedInterval;
    _expectedPrior = expected;
    _receivedPrior = _received;
    if (expectedInterval <= 0 || lostInterval <= 0) return 0;
    return ((lostInterval << 8) ~/ expectedInterval) & 0xFF;
  }

  /// LSR (middle 32 bits of the most recent SR's NTP timestamp).
  int get lastSrMiddle32 => _lastSrMiddle32;

  /// DLSR in 1/65536 second units, since the last SR was received.
  int get delaySinceLastSr {
    if (_lastSrArrivalUnixMicros == 0) return 0;
    final dtMicros =
        DateTime.now().microsecondsSinceEpoch - _lastSrArrivalUnixMicros;
    if (dtMicros <= 0) return 0;
    // 1 second = 65536 units; convert micros → units.
    return ((dtMicros * 65536) ~/ 1000000) & 0xFFFFFFFF;
  }

  /// Record receipt of an inbound RTP packet and update jitter / loss stats.
  /// `clockRate` is the codec's RTP clock rate (8000 for G.711).
  void onReceived(RtpPacket pkt, int clockRate) {
    final ssrc = pkt.ssrc;
    if (remoteSsrc == null) {
      remoteSsrc = ssrc;
      _initSeq(pkt.sequenceNumber);
      // Per RFC 3550 A.1, received stays 0 until probation completes.
      _maxSeq = pkt.sequenceNumber - 1;
    } else if (remoteSsrc != ssrc) {
      // SSRC change — reset.
      remoteSsrc = ssrc;
      _initSeq(pkt.sequenceNumber);
      _cycles = 0;
      _received = 0;
      _expectedPrior = 0;
      _receivedPrior = 0;
      _haveTransit = false;
      _jitter = 0;
    }
    _updateSeq(pkt.sequenceNumber);

    // Jitter: D = (Rj - Ri) - (Sj - Si); J += (|D| - J) / 16.
    final arrivalRtp =
        ((DateTime.now().microsecondsSinceEpoch * clockRate) ~/ 1000000) &
        0xFFFFFFFF;
    final transit = (arrivalRtp - pkt.timestamp).toSigned(32);
    if (_haveTransit) {
      var d = transit - _transit;
      if (d < 0) d = -d;
      _jitter += (d - _jitter) / 16.0;
    }
    _transit = transit;
    _haveTransit = true;
  }

  /// Record an inbound SR so we can fill LSR/DLSR in our next RR.
  void onSenderReport(int middle32) {
    _lastSrMiddle32 = middle32;
    _lastSrArrivalUnixMicros = DateTime.now().microsecondsSinceEpoch;
  }

  /// Have we received any RTP from the peer yet?
  bool get hasInbound => remoteSsrc != null && _received > 0;

  // ---- RFC 3550 Appendix A.1 ---------------------------------------------

  void _initSeq(int seq) {
    _baseSeq = seq;
    _maxSeq = seq;
    _badSeq = -1;
    _probation = true;
    _probationCount = 2;
  }

  void _updateSeq(int seq) {
    const maxDropout = 3000;
    const maxMisorder = 100;
    const seqMod = 1 << 16;

    final udelta = (seq - _maxSeq) & 0xFFFF;

    if (_probation) {
      if (seq == ((_maxSeq + 1) & 0xFFFF)) {
        _probationCount--;
        _maxSeq = seq;
        if (_probationCount == 0) {
          _initSeq(seq);
          _received++;
          _probation = false;
        }
      } else {
        _probationCount = 1;
        _maxSeq = seq;
      }
      return;
    }

    if (udelta < maxDropout) {
      if (seq < _maxSeq) {
        _cycles = (_cycles + 1) & 0xFFFF;
      }
      _maxSeq = seq;
    } else if (udelta <= seqMod - maxMisorder) {
      // Big jump: assume restart if it happens twice.
      if (seq == _badSeq) {
        _initSeq(seq);
      } else {
        _badSeq = (seq + 1) & 0xFFFF;
        return;
      }
    } else {
      // Old/duplicate packet — count it but don't move max.
    }
    _received++;
  }
}
