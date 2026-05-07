import 'dart:typed_data';

import 'package:flutter_sip_ua/sip/audio/audio_sink.dart';
import 'package:flutter_sip_ua/sip/audio/jitter_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

PcmFrame _frame(int seq) => PcmFrame(
  pcm: Int16List.fromList(List<int>.filled(160, seq & 0x7F)),
  sampleRate: 8000,
  timestamp: seq * 160,
);

void main() {
  group('JitterBuffer', () {
    test('does not release until target depth is reached', () {
      final sink = CapturingAudioSink();
      final jb = JitterBuffer(sink: sink, targetFrames: 3);

      jb.push(1, _frame(1));
      jb.push(2, _frame(2));
      jb.push(3, _frame(3));
      expect(sink.frames, isEmpty);

      jb.push(4, _frame(4));
      expect(sink.frames, hasLength(1));
      expect(sink.frames.first.pcm.first, 1);
      expect(jb.length, 3);
    });

    test('releases frames in monotonic sequence order', () {
      final sink = CapturingAudioSink();
      final jb = JitterBuffer(sink: sink, targetFrames: 2);

      jb.push(10, _frame(10));
      jb.push(11, _frame(11));
      jb.push(12, _frame(12));
      jb.push(13, _frame(13));
      jb.push(14, _frame(14));
      jb.tick();
      jb.tick();
      jb.tick();

      expect(sink.frames.map((f) => f.pcm.first).toList(), [
        10,
        11,
        12,
        13,
        14,
      ]);
    });

    test('reorders out-of-order arrivals before release', () {
      final sink = CapturingAudioSink();
      final jb = JitterBuffer(sink: sink, targetFrames: 3);

      jb.push(1, _frame(1));
      jb.push(3, _frame(3));
      jb.push(2, _frame(2));
      jb.push(4, _frame(4));
      jb.push(5, _frame(5));
      jb.tick();
      jb.tick();
      jb.tick();

      expect(sink.frames.map((f) => f.pcm.first).toList(), [1, 2, 3, 4, 5]);
    });

    test('drops frames that arrive after their slot has played', () {
      final sink = CapturingAudioSink();
      final jb = JitterBuffer(sink: sink, targetFrames: 1);

      jb.push(1, _frame(1));
      jb.push(2, _frame(2));
      // frame 1 was released by push(2) crossing the target.
      expect(sink.frames.map((f) => f.pcm.first), [1]);

      // Now a stale copy of seq 1 arrives — must be dropped.
      jb.push(1, _frame(1));
      expect(jb.lateDrops, 1);
      expect(sink.frames, hasLength(1));
    });

    test('ignores duplicate sequence numbers still in the queue', () {
      final sink = CapturingAudioSink();
      final jb = JitterBuffer(sink: sink, targetFrames: 4);

      jb.push(50, _frame(50));
      jb.push(50, _frame(50));
      expect(jb.length, 1);
      expect(jb.lateDrops, 0);
    });

    test('caps depth at maxFrames and counts overflow drops', () {
      final sink = CapturingAudioSink();
      // Equal target & max means the release loop only runs once per push,
      // so the second push of the same depth triggers the overflow cap.
      final jb = JitterBuffer(sink: sink, targetFrames: 4, maxFrames: 4);

      // Push frames out of order so reordering inserts at index 0 and
      // pushes the existing tail past maxFrames before the release loop
      // gets a chance to drain it.
      jb.push(10, _frame(10));
      jb.push(11, _frame(11));
      jb.push(12, _frame(12));
      jb.push(13, _frame(13));
      // Inserting an older sequence at the head bumps depth to 5, the
      // overflow cap drops the oldest of the new ordering.
      jb.push(9, _frame(9));

      expect(jb.overflowDrops, greaterThanOrEqualTo(1));
      expect(jb.length, lessThanOrEqualTo(4));
    });

    test('handles 16-bit sequence wrap-around', () {
      final sink = CapturingAudioSink();
      final jb = JitterBuffer(sink: sink, targetFrames: 2);

      jb.push(0xFFFE, _frame(0xFFFE));
      jb.push(0xFFFF, _frame(0xFFFF));
      jb.push(0x0000, _frame(0x0000));
      jb.push(0x0001, _frame(0x0001));
      jb.tick();
      jb.tick();

      expect(sink.frames.map((f) => f.timestamp).toList(), [
        0xFFFE * 160,
        0xFFFF * 160,
        0,
        160,
      ]);
    });

    test('tick releases at most one frame per call', () {
      final sink = CapturingAudioSink();
      final jb = JitterBuffer(sink: sink, targetFrames: 2);

      jb.push(1, _frame(1));
      jb.push(2, _frame(2));
      jb.push(3, _frame(3));
      jb.push(4, _frame(4));
      // queue depth = 4, target = 2 → push already released 2 frames.
      final preTickCount = sink.frames.length;
      jb.tick();
      expect(sink.frames.length, preTickCount + 1);
    });

    test('close flushes remaining frames and closes the sink', () async {
      final sink = CapturingAudioSink();
      final jb = JitterBuffer(sink: sink, targetFrames: 5);

      jb.push(1, _frame(1));
      jb.push(2, _frame(2));
      expect(sink.frames, isEmpty);

      await jb.close();
      expect(sink.frames.map((f) => f.pcm.first).toList(), [1, 2]);
      expect(sink.closed, isTrue);
    });

    test('refuses input after close', () async {
      final sink = CapturingAudioSink();
      final jb = JitterBuffer(sink: sink);
      await jb.close();
      jb.push(1, _frame(1));
      expect(sink.frames, isEmpty);
    });
  });

  group('NullAudioSink', () {
    test('discards frames and closes cleanly', () async {
      const sink = NullAudioSink();
      sink.play(_frame(1));
      await sink.close();
    });
  });
}
