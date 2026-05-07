/// Pluggable video codec for [VideoSession].
///
/// Two implementations ship in this UA:
///
///   * [PassthroughVideoCodec] — used by tests and any caller that wants
///     to feed pre-encoded bytestream frames straight onto the wire (e.g.
///     server-recorded VP8 files, file-based loopback).
///   * `PureDartVpxAdapter` — a placeholder that hooks a future
///     `package:pure_dart_vpx` build into the same interface. As of this
///     writing the upstream package only contains skeleton code, so the
///     adapter throws [UnimplementedError]. Replace the body once the
///     real encoder/decoder ships.
///
/// The shape of the interface is deliberately minimal so it can target
/// hardware codecs (FFI, plugin) too — encoders accept a YUV420p frame
/// and return one or more compressed frames; decoders accept a single
/// compressed frame and return zero or one decoded YUV420p frames.
library;

import 'dart:typed_data';

import '../sdp.dart';

/// I420 (YUV 4:2:0) frame.
///
/// All three planes share the same image size; chroma planes are
/// half-width, half-height. Strides default to plane width.
class YuvFrame {
  YuvFrame({
    required this.width,
    required this.height,
    required this.y,
    required this.u,
    required this.v,
    int? yStride,
    int? uStride,
    int? vStride,
  }) : yStride = yStride ?? width,
       uStride = uStride ?? width ~/ 2,
       vStride = vStride ?? width ~/ 2;

  final int width;
  final int height;
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final int yStride;
  final int uStride;
  final int vStride;
}

/// Encoded compressed-video frame plus a hint of whether it's a key frame.
class EncodedVideoFrame {
  EncodedVideoFrame({
    required this.bytes,
    required this.keyFrame,
    required this.timestamp,
  });

  /// Raw bytestream for the codec (e.g. a VP8 frame).
  final Uint8List bytes;
  final bool keyFrame;

  /// 90 kHz RTP timestamp.
  final int timestamp;
}

abstract class VideoEncoder {
  SdpVideoCodec get codec;

  /// Encode a single raw YUV frame. May return zero, one, or more
  /// compressed frames (some encoders rate-control by skipping).
  List<EncodedVideoFrame> encode(YuvFrame frame, {bool forceKeyframe = false});

  /// Release native resources (no-op for pure-Dart codecs).
  void close();
}

abstract class VideoDecoder {
  SdpVideoCodec get codec;

  /// Decode one encoded frame and return the YUV picture, or null if the
  /// codec needs more data (e.g. the inbound stream hasn't seen a keyframe
  /// yet).
  YuvFrame? decode(Uint8List bytes);

  void close();
}

/// Pretends to encode by handing the input bytes back out unchanged.
/// Useful for tests and for piping pre-encoded frames through the RTP
/// transport.
class PassthroughVideoCodec implements VideoEncoder, VideoDecoder {
  PassthroughVideoCodec({this.codec = SdpVideoCodec.vp8});

  @override
  final SdpVideoCodec codec;

  /// In passthrough mode `encode` accepts raw bitstream wrapped as a
  /// fake `YuvFrame` whose `y` plane carries the bytestream. Caller
  /// should keep `width`/`height` populated for upper layers but the
  /// chroma planes are unused.
  @override
  List<EncodedVideoFrame> encode(YuvFrame frame, {bool forceKeyframe = false}) {
    return [
      EncodedVideoFrame(
        bytes: Uint8List.fromList(frame.y),
        keyFrame: forceKeyframe,
        timestamp: 0,
      ),
    ];
  }

  @override
  YuvFrame? decode(Uint8List bytes) {
    return YuvFrame(
      width: bytes.length,
      height: 1,
      y: Uint8List.fromList(bytes),
      u: Uint8List(0),
      v: Uint8List(0),
    );
  }

  @override
  void close() {}
}

/// Adapter slot for `package:pure_dart_vpx`.
///
/// The upstream repository (https://github.com/KellyKinyama/pure-dart-vpx)
/// is still scaffolding — it does not yet expose a working encode/decode
/// API. When it does, replace the bodies below with calls into it.
class PureDartVpxAdapter implements VideoEncoder, VideoDecoder {
  @override
  SdpVideoCodec get codec => SdpVideoCodec.vp8;

  @override
  List<EncodedVideoFrame> encode(YuvFrame frame, {bool forceKeyframe = false}) {
    throw UnimplementedError(
      'pure-dart-vpx encoder not yet wired. Provide an encoder via '
      'VideoSession(encoder: ...).',
    );
  }

  @override
  YuvFrame? decode(Uint8List bytes) {
    throw UnimplementedError(
      'pure-dart-vpx decoder not yet wired. Provide a decoder via '
      'VideoSession(decoder: ...).',
    );
  }

  @override
  void close() {}
}
