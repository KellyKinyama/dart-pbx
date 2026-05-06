// Minimal structured logger for production use.
//
// Replaces ad-hoc `print(...)` calls so a deployment can quiet the SIP
// router down to errors only or pipe the output into journald / syslog.
//
// Levels (lower = more important):
//   0 = error
//   1 = warn
//   2 = info  (default)
//   3 = debug
//
// Configure via the `LOG_LEVEL` env var (`error`, `warn`, `info`, `debug`)
// or programmatically with `Log.level = LogLevel.debug`.

import 'dart:io';

enum LogLevel { error, warn, info, debug }

class Log {
  static LogLevel level = _initialLevel();

  static LogLevel _initialLevel() {
    final raw = Platform.environment['LOG_LEVEL']?.toLowerCase();
    switch (raw) {
      case 'error':
        return LogLevel.error;
      case 'warn':
      case 'warning':
        return LogLevel.warn;
      case 'debug':
      case 'trace':
        return LogLevel.debug;
      case 'info':
      default:
        return LogLevel.info;
    }
  }

  static void error(String tag, String msg) => _emit(LogLevel.error, tag, msg);
  static void warn(String tag, String msg) => _emit(LogLevel.warn, tag, msg);
  static void info(String tag, String msg) => _emit(LogLevel.info, tag, msg);
  static void debug(String tag, String msg) => _emit(LogLevel.debug, tag, msg);

  /// Optional sink for raw SIP payloads (dumped via [Log.dumpSip]). When
  /// `null` (default) raw dumps are silently discarded. Set the
  /// `SIP_DUMP_FILE` env var or call [Log.openSipDump] to enable.
  static IOSink? _sipSink = _initialSipSink();
  static String? _sipSinkPath;

  static IOSink? _initialSipSink() {
    final p = Platform.environment['SIP_DUMP_FILE'];
    if (p == null || p.isEmpty) return null;
    return _openSink(p);
  }

  static IOSink? _openSink(String path) {
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      _sipSinkPath = path;
      return f.openWrite(mode: FileMode.append);
    } catch (e) {
      stderr.writeln('Log: cannot open SIP dump file $path: $e');
      return null;
    }
  }

  /// Switch (or open) the raw SIP dump file at runtime.
  static void openSipDump(String path) {
    _sipSink?.flush();
    _sipSink?.close();
    _sipSink = _openSink(path);
  }

  /// Append a raw SIP payload to the dump file with a header line. Safe to
  /// call when no dump file is configured (it becomes a no-op).
  static void dumpSip(String tag, String raw, {String? srcIp, int? srcPort}) {
    final sink = _sipSink;
    if (sink == null) return;
    final ts = DateTime.now().toIso8601String();
    final src = (srcIp == null) ? '' : ' from $srcIp:${srcPort ?? 0}';
    sink.writeln('---- $ts [$tag]$src ${raw.length}B ----');
    if (raw.isEmpty) {
      sink.writeln('<empty datagram>');
    } else {
      sink.writeln(raw);
      final units = raw.codeUnits;
      final n = units.length > 256 ? 256 : units.length;
      final hex = StringBuffer('hex: ');
      for (var i = 0; i < n; i++) {
        hex.write(units[i].toRadixString(16).padLeft(2, '0'));
        if (i < n - 1) hex.write(' ');
      }
      if (units.length > n) hex.write(' ... (+${units.length - n} more)');
      sink.writeln(hex);
    }
    sink.writeln();
    sink.flush();
  }

  static void _emit(LogLevel lvl, String tag, String msg) {
    if (lvl.index > level.index) return;
    final ts = DateTime.now().toIso8601String();
    final line = '$ts [${lvl.name.toUpperCase()}] $tag: $msg';
    if (lvl == LogLevel.error || lvl == LogLevel.warn) {
      stderr.writeln(line);
    } else {
      stdout.writeln(line);
    }
  }
}
