import 'dart:typed_data';

/// Audio frame ready for playback. The PCM is 16-bit signed little-endian
/// at the negotiated [sampleRate], one channel.
class PcmFrame {
  const PcmFrame({
    required this.pcm,
    required this.sampleRate,
    required this.timestamp,
  });

  /// 16-bit signed PCM samples, mono.
  final Int16List pcm;

  /// Sample rate of [pcm] in Hz (8000 for narrowband G.711).
  final int sampleRate;

  /// 32-bit RTP timestamp of the original packet, kept for diagnostics
  /// and re-ordering by callers that want to drive their own clock.
  final int timestamp;
}

/// Where decoded audio frames go for playback.
///
/// The default [NullAudioSink] discards everything so the existing
/// signalling-only behaviour is preserved if no real sink is provided.
/// Real implementations (Flutter plugin, FFI, file dump for tests) just
/// implement [play] / [close].
abstract class AudioSink {
  /// Hand a freshly-decoded PCM frame to the player. Implementations should
  /// return as quickly as possible — decoding runs on the network event
  /// loop and back-pressure here will starve the jitter buffer.
  void play(PcmFrame frame);

  /// Release any platform resources. Called once when the call ends.
  Future<void> close();
}

/// Drops every frame. Used until the host app wires in a real sink.
class NullAudioSink implements AudioSink {
  const NullAudioSink();

  @override
  void play(PcmFrame frame) {}

  @override
  Future<void> close() async {}
}

/// In-memory sink used by tests: keeps every frame so assertions can
/// inspect what would have been played.
class CapturingAudioSink implements AudioSink {
  final List<PcmFrame> frames = <PcmFrame>[];
  bool closed = false;

  @override
  void play(PcmFrame frame) => frames.add(frame);

  @override
  Future<void> close() async {
    closed = true;
  }
}
