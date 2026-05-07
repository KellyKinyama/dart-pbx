/// Append-only SIP wire-format logger. One file per launch; every inbound
/// and outbound message is written verbatim with a timestamp + direction
/// header so the file can be diffed against an Asterisk / dart-pbx pcap.
///
/// Not used on `dart:js` targets — file IO requires `dart:io`.
library;

import 'dart:async';
import 'dart:io';

import 'sip_message.dart';

class SipFileLogger {
  SipFileLogger(this.path);

  /// Absolute path to the log file.
  final String path;

  IOSink? _sink;

  /// Open (or create) the file in append mode. Synchronous so it's ready
  /// before any SIP traffic flows. Safe to call more than once.
  void open() {
    if (_sink != null) return;
    final f = File(path);
    f.parent.createSync(recursive: true);
    _sink = f.openWrite(mode: FileMode.append);
    _sink!
      ..writeln()
      ..writeln(
        '################################################################',
      )
      ..writeln('# session start  ${DateTime.now().toIso8601String()}')
      ..writeln('# pid            $pid')
      ..writeln(
        '################################################################',
      );
  }

  /// Log a parsed message we just sent (`OUT`) or received (`IN`).
  void log(String direction, SipMessage msg) {
    final s = _sink;
    if (s == null) return;
    final summary = msg.isResponse
        ? '${msg.statusCode} ${msg.reasonPhrase}'
        : '${msg.method} ${msg.requestUri}';
    s
      ..writeln()
      ..writeln(
        '----- ${DateTime.now().toIso8601String()}  $direction  $summary -----',
      )
      ..write(msg.encode());
  }

  /// Log a free-form line (transport state changes, errors, ...).
  void note(String line) {
    final s = _sink;
    if (s == null) return;
    s.writeln('# ${DateTime.now().toIso8601String()}  $line');
  }

  Future<void> close() async {
    final s = _sink;
    _sink = null;
    if (s == null) return;
    try {
      await s.flush();
    } catch (_) {}
    try {
      await s.close();
    } catch (_) {}
  }
}
