/// Cross-platform [AudioSink] that pushes decoded PCM into
/// `flutter_pcm_sound`. Works on Windows / macOS / Linux / Android / iOS.
///
/// The plugin is a process-wide singleton, so only one [PcmAudioSink]
/// should be active at a time. [close] releases the platform engine.
library;

import 'dart:async';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import 'audio_sink.dart';

class PcmAudioSink implements AudioSink {
  PcmAudioSink({this.sampleRate = 8000});

  /// 8000 for narrowband G.711, the only codec we negotiate.
  final int sampleRate;

  bool _setup = false;
  bool _closed = false;
  Future<void>? _setupFuture;

  Future<void> _ensureSetup() {
    if (_closed) return Future.value();
    if (_setup) return Future.value();
    return _setupFuture ??= () async {
      await FlutterPcmSound.setLogLevel(LogLevel.error);
      await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
      // Ask the engine to keep at least 320 samples (40 ms) buffered.
      await FlutterPcmSound.setFeedThreshold(320);
      _setup = true;
    }();
  }

  @override
  void play(PcmFrame frame) {
    if (_closed) return;
    // Fire-and-forget: the network event loop must not await audio I/O.
    _enqueue(frame);
  }

  Future<void> _enqueue(PcmFrame frame) async {
    try {
      await _ensureSetup();
      if (_closed) return;
      await FlutterPcmSound.feed(
        PcmArrayInt16(bytes: frame.pcm.buffer.asByteData()),
      );
    } catch (_) {
      // Swallow: a single dropped frame must not poison the call.
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
  }
}
