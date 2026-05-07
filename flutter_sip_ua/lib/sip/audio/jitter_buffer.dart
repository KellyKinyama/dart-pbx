import 'audio_sink.dart';

/// Small fixed-target playout buffer for inbound RTP audio.
///
/// Real-time audio arrives with packet-to-packet timing jitter, occasional
/// reordering, and occasional loss. A jitter buffer absorbs all three by
/// holding a few frames before handing them to the audio sink in strict
/// timestamp order.
///
/// The implementation is deliberately conservative and pure-Dart so it
/// can be unit-tested without sockets or platform plugins:
///
///   * Frames are kept in a sequence-number-keyed map.
///   * On [push] a frame is queued. If the buffer holds at least
///     [targetFrames] frames, the oldest is released to the sink.
///   * Late frames (older than the highest released sequence) are
///     dropped and counted in [lateDrops].
///   * Reordering across the 16-bit sequence wrap-around is detected by
///     comparing the signed 16-bit difference between two sequence
///     numbers (RFC 3550 §A.1).
///   * Long stalls are detected via [tick]: callers can pump the clock
///     on a 20 ms timer to release queued frames even when the network
///     has gone quiet.
class JitterBuffer {
  JitterBuffer({required this.sink, this.targetFrames = 3, this.maxFrames = 12})
    : assert(targetFrames >= 1),
      assert(maxFrames >= targetFrames);

  /// Where to write released frames.
  final AudioSink sink;

  /// Steady-state depth in frames before we start releasing. With G.711's
  /// 20 ms packetisation a target of 3 ≈ 60 ms of latency, which is what
  /// most softphones use for cellular networks.
  final int targetFrames;

  /// Hard ceiling on queue depth. Above this the oldest queued frames
  /// are dropped (to prevent unbounded growth on a stuck consumer).
  final int maxFrames;

  /// Frames received that arrived after their slot was already played out.
  int lateDrops = 0;

  /// Frames discarded because the queue overflowed [maxFrames].
  int overflowDrops = 0;

  /// Number of frames the sink has been handed.
  int playedFrames = 0;

  final Map<int, PcmFrame> _queue = <int, PcmFrame>{};
  final List<int> _seqs = <int>[];
  int? _lastReleasedSeq;
  bool _playing = false;
  bool _closed = false;

  /// Number of frames currently buffered.
  int get length => _seqs.length;

  /// Hand a freshly-decoded inbound frame to the buffer, identified by its
  /// 16-bit RTP sequence number. Releases zero or more frames to the sink
  /// as a side effect.
  void push(int sequenceNumber, PcmFrame frame) {
    if (_closed) return;
    final seq = sequenceNumber & 0xFFFF;

    final last = _lastReleasedSeq;
    if (last != null && _signedDiff(seq, last) <= 0) {
      // Late or duplicate of something we've already played out.
      lateDrops++;
      return;
    }
    if (_queue.containsKey(seq)) {
      // Duplicate that hasn't been played yet — keep the first copy.
      return;
    }

    _queue[seq] = frame;
    _insertSorted(seq);

    // If we've blown past the ceiling, drop the oldest to keep latency
    // bounded.
    while (_seqs.length > maxFrames) {
      final dropped = _seqs.removeAt(0);
      _queue.remove(dropped);
      overflowDrops++;
    }

    while (_seqs.length > targetFrames) {
      _releaseOldest();
    }
    // Once we've reached the target depth at least once, switch to
    // "playing" mode where [tick] will continue draining one frame at a
    // time even if the queue dips below the target (steady-state playout).
    if (_seqs.length >= targetFrames) _playing = true;
  }

  /// Pump the clock without a packet arriving (e.g. a 20 ms timer). One
  /// call releases at most one frame so callers can drive playback at a
  /// steady cadence even during silence.
  void tick() {
    if (_closed) return;
    if (!_playing) {
      if (_seqs.length >= targetFrames) {
        _playing = true;
      } else {
        return;
      }
    }
    if (_seqs.isNotEmpty) {
      _releaseOldest();
    }
  }

  /// Flush every buffered frame to the sink and stop accepting input.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    while (_seqs.isNotEmpty) {
      _releaseOldest();
    }
    await sink.close();
  }

  void _releaseOldest() {
    if (_seqs.isEmpty) return;
    final seq = _seqs.removeAt(0);
    final frame = _queue.remove(seq);
    if (frame == null) return;
    _lastReleasedSeq = seq;
    playedFrames++;
    sink.play(frame);
  }

  void _insertSorted(int seq) {
    // Linear insertion ordered by signed-16 distance from the current
    // tail. The queue is at most [maxFrames] deep so this is O(maxFrames).
    if (_seqs.isEmpty) {
      _seqs.add(seq);
      return;
    }
    for (var i = 0; i < _seqs.length; i++) {
      if (_signedDiff(seq, _seqs[i]) < 0) {
        _seqs.insert(i, seq);
        return;
      }
    }
    _seqs.add(seq);
  }

  /// Signed 16-bit distance from [a] to [b]. Positive means [a] is newer.
  static int _signedDiff(int a, int b) {
    final d = ((a - b) & 0xFFFF);
    return d >= 0x8000 ? d - 0x10000 : d;
  }
}
