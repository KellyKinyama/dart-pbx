// Helpers for parsing, generating, and rewriting raw SIP messages.
//
// The hand-rolled parser in `lib/sip_parser` already gives us a [SipMsg] with
// most fields broken out, but the running proxy still needs to mutate the raw
// wire form (add Via, decrement Max-Forwards, append a tag, etc.). These
// helpers concentrate that logic in one place so handlers don't keep
// reinventing it.

import 'dart:math';

import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/sip_parser/sip_via.dart';

const String crlf = '\r\n';
const String _branchMagicCookie = 'z9hG4bK';
const String _tagAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

final Random _rng = Random.secure();

String _randomToken(int length) {
  final buf = StringBuffer();
  for (var i = 0; i < length; i++) {
    buf.write(_tagAlphabet[_rng.nextInt(_tagAlphabet.length)]);
  }
  return buf.toString();
}

/// Generates a Via branch parameter (RFC 3261 §8.1.1.7) including the magic
/// cookie required for transaction matching.
String generateBranch() => '$_branchMagicCookie-${_randomToken(16)}';

/// Generates a To/From tag (RFC 3261 §19.3).
String generateTag() => _randomToken(10);

/// Generates a globally unique Call-ID.
String generateCallId(String host) => '${_randomToken(16)}@$host';

/// Returns the topmost Via header (the one this hop or the next downstream hop
/// must match against). May be null if the message has no Via at all.
sipVia? topVia(SipMsg msg) => msg.Via.isEmpty ? null : msg.Via.first;

/// Returns the `host[:port]` "sent-by" portion of a Via for transaction
/// matching per RFC 3261 §17.2.3.
String sentBy(sipVia via) {
  final h = via.Host ?? '';
  final p = via.Port;
  return '$h${p == null ? '' : ':$p'}';
}

/// Returns the CSeq method (always upper-case) or null when absent.
String? cseqMethod(SipMsg msg) {
  return msg.Cseq.Method?.trim().toUpperCase();
}

/// Returns the numeric CSeq sequence number or null when absent / unparseable.
int? cseqNumber(SipMsg msg) {
  final s = msg.Cseq.Id;
  return s == null ? null : int.tryParse(s.trim());
}

/// True when this message belongs inside an established (or re-INVITE)
/// dialog, i.e. it carries both a From-tag and a To-tag.
bool isInDialog(SipMsg msg) =>
    (msg.From.Tag?.isNotEmpty ?? false) && (msg.To.Tag?.isNotEmpty ?? false);

/// Returns the request method or null if [msg] is a response.
String? requestMethod(SipMsg msg) {
  final m = msg.Req.Method;
  return (m == null || m.isEmpty) ? null : m.toUpperCase();
}

/// Returns the response status code or null if [msg] is a request.
int? responseStatus(SipMsg msg) {
  final c = msg.Req.StatusCode;
  return c == null ? null : int.tryParse(c.trim());
}

/// Splits a raw message into header lines (without the trailing blank line)
/// and the body portion.
({List<String> headers, String body}) splitMessage(String raw) {
  final headerEnd = raw.indexOf('$crlf$crlf');
  if (headerEnd < 0) {
    return (headers: raw.split(crlf), body: '');
  }
  final headers = raw.substring(0, headerEnd).split(crlf);
  final body = raw.substring(headerEnd + 4);
  return (headers: headers, body: body);
}

/// Joins header lines and body back into a wire-format message terminated by a
/// blank line as required by RFC 3261 §7.5.
String joinMessage(List<String> headers, String body) {
  final buf = StringBuffer();
  for (final h in headers) {
    buf
      ..write(h)
      ..write(crlf);
  }
  buf.write(crlf);
  buf.write(body);
  return buf.toString();
}

bool _headerIs(String line, String name) {
  final lower = line.toLowerCase();
  return lower.startsWith('${name.toLowerCase()}:') ||
      lower.startsWith('${name.toLowerCase()} :');
}

/// Returns the first header line whose name matches [name] (case-insensitive),
/// or null if absent.
String? findHeader(List<String> headers, String name) {
  for (final h in headers) {
    if (_headerIs(h, name)) return h;
  }
  return null;
}

/// Removes every header with [name] (case-insensitive). Returns the new list.
List<String> removeHeaders(List<String> headers, String name) =>
    headers.where((h) => !_headerIs(h, name)).toList(growable: true);

/// Decrements the Max-Forwards header in [headers] (RFC 3261 §16.6.3). If the
/// header is missing it is added with value 70. Returns the new value or null
/// when it would underflow to 0 (caller should respond 483 Too Many Hops).
int? decrementMaxForwards(List<String> headers) {
  for (var i = 0; i < headers.length; i++) {
    if (_headerIs(headers[i], 'Max-Forwards')) {
      final colon = headers[i].indexOf(':');
      final value = int.tryParse(headers[i].substring(colon + 1).trim()) ?? 70;
      if (value <= 0) return null;
      headers[i] = 'Max-Forwards: ${value - 1}';
      return value - 1;
    }
  }
  headers.insert(1, 'Max-Forwards: 70');
  return 70;
}

/// Adds a Via header line at the top of the message (right after the request
/// line). Used by a stateful proxy when forwarding upstream so it can match
/// the eventual response back to its client transaction.
void prependVia(List<String> headers, String viaLine) {
  headers.insert(1, viaLine);
}

/// Pops the topmost Via header (the proxy's own). Returns the removed line, or
/// null if no Via was present. Caller uses this when forwarding a response
/// downstream per RFC 3261 §16.7.
String? popTopVia(List<String> headers) {
  for (var i = 0; i < headers.length; i++) {
    if (_headerIs(headers[i], 'Via') || _headerIs(headers[i], 'v')) {
      return headers.removeAt(i);
    }
  }
  return null;
}

/// Inserts a Record-Route header right after the request line (top of the
/// stack). The proxy adds this on the initial INVITE so that subsequent
/// in-dialog requests are routed back through it (RFC 3261 §16.6.4).
void addRecordRoute(List<String> headers, String routeUri) {
  headers.insert(1, 'Record-Route: <$routeUri>');
}

/// Returns the list of Route header *URIs* (without surrounding angle
/// brackets), in arrival order. Multiple comma-separated values within a
/// single header line are split.
List<String> readRoutes(List<String> headers) {
  final out = <String>[];
  for (final h in headers) {
    if (!_headerIs(h, 'Route')) continue;
    final colon = h.indexOf(':');
    if (colon < 0) continue;
    final value = h.substring(colon + 1);
    for (final entry in _splitCommaOutsideBrackets(value)) {
      final trimmed = entry.trim();
      final lt = trimmed.indexOf('<');
      final gt = trimmed.lastIndexOf('>');
      if (lt >= 0 && gt > lt) {
        out.add(trimmed.substring(lt + 1, gt));
      } else if (trimmed.isNotEmpty) {
        out.add(trimmed);
      }
    }
  }
  return out;
}

/// Returns the Record-Route URIs (top-down). Used to seed a dialog's route
/// set per RFC 3261 §12.1.1 / §12.1.2.
List<String> readRecordRoutes(List<String> headers) {
  final out = <String>[];
  for (final h in headers) {
    if (!_headerIs(h, 'Record-Route')) continue;
    final colon = h.indexOf(':');
    if (colon < 0) continue;
    final value = h.substring(colon + 1);
    for (final entry in _splitCommaOutsideBrackets(value)) {
      final trimmed = entry.trim();
      final lt = trimmed.indexOf('<');
      final gt = trimmed.lastIndexOf('>');
      if (lt >= 0 && gt > lt) {
        out.add(trimmed.substring(lt + 1, gt));
      } else if (trimmed.isNotEmpty) {
        out.add(trimmed);
      }
    }
  }
  return out;
}

/// Removes the topmost Route header value if its URI host:port matches
/// [selfHost]:[selfPort] (loose routing per RFC 3261 §16.4). Returns true
/// when a Route was consumed.
bool consumeTopRouteIfSelf(
    List<String> headers, String selfHost, int selfPort) {
  for (var i = 0; i < headers.length; i++) {
    if (!_headerIs(headers[i], 'Route')) continue;
    final line = headers[i];
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final value = line.substring(colon + 1);
    final entries = _splitCommaOutsideBrackets(value);
    if (entries.isEmpty) {
      headers.removeAt(i);
      return false;
    }
    final first = entries.first.trim();
    final lt = first.indexOf('<');
    final gt = first.lastIndexOf('>');
    final uri = (lt >= 0 && gt > lt) ? first.substring(lt + 1, gt) : first;
    final hp = _hostPort(uri);
    final matches = hp.host == selfHost &&
        (hp.port == selfPort || (hp.port == null && selfPort == 5060));
    if (!matches) return false;
    if (entries.length == 1) {
      headers.removeAt(i);
    } else {
      headers[i] = 'Route:${entries.skip(1).join(',')}';
    }
    return true;
  }
  return false;
}

/// Splits a comma-separated header value while ignoring commas inside angle
/// brackets (so `<sip:a;p=1,2>` stays intact).
List<String> _splitCommaOutsideBrackets(String value) {
  final out = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (c == '<') {
      depth++;
    } else if (c == '>') {
      depth--;
    } else if (c == ',' && depth == 0) {
      out.add(value.substring(start, i));
      start = i + 1;
    }
  }
  out.add(value.substring(start));
  return out;
}

/// Parses `host:port` (with an optional scheme prefix and trailing
/// parameters) out of a URI into a (host, port) pair.
({String host, int? port}) _hostPort(String uri) {
  var s = uri;
  // Strip scheme.
  final schemeIdx = s.indexOf(':');
  if (schemeIdx >= 0 && schemeIdx < 6) {
    s = s.substring(schemeIdx + 1);
  }
  // Strip user@.
  final at = s.indexOf('@');
  if (at >= 0) s = s.substring(at + 1);
  // Strip params.
  final semi = s.indexOf(';');
  if (semi >= 0) s = s.substring(0, semi);
  final colon = s.indexOf(':');
  if (colon < 0) return (host: s, port: null);
  return (
    host: s.substring(0, colon),
    port: int.tryParse(s.substring(colon + 1))
  );
}

/// Public version of [_hostPort] for callers that need to resolve a Contact
/// or Route URI to a transport target.
({String host, int? port}) parseUriHostPort(String uri) => _hostPort(uri);

/// Sets (or replaces) a header. If the header already exists every occurrence
/// is removed and a single new line is inserted near the top.
void setHeader(List<String> headers, String name, String value) {
  for (var i = headers.length - 1; i >= 1; i--) {
    if (_headerIs(headers[i], name)) headers.removeAt(i);
  }
  headers.insert(1, '$name: $value');
}

/// Appends `;tag=<tag>` to the To header if it does not already carry one.
/// Returns the tag actually present after the call.
String ensureToTag(List<String> headers, String tag) {
  for (var i = 0; i < headers.length; i++) {
    if (_headerIs(headers[i], 'To') || _headerIs(headers[i], 't')) {
      final line = headers[i];
      final lower = line.toLowerCase();
      final tagIdx = lower.indexOf(';tag=');
      if (tagIdx >= 0) {
        // Already tagged; extract and return the existing one.
        var end = line.indexOf(';', tagIdx + 1);
        if (end < 0) end = line.length;
        return line.substring(tagIdx + 5, end);
      }
      headers[i] = '$line;tag=$tag';
      return tag;
    }
  }
  return tag;
}

/// Builds a response to [request] from scratch using the rules of RFC 3261
/// §8.2.6 (copy Via/From/To/Call-ID/CSeq, set To-tag if needed). The response
/// is suitable for sending downstream by a UAS or a stateful proxy generating
/// its own response (e.g. 100 Trying, 487 Request Terminated).
///
/// [toTag] is the tag this entity wants to advertise on the To header. For
/// 100-class responses it is omitted (RFC 3261 §8.2.6.2).
String buildResponse(
  SipMsg request, {
  required int code,
  required String reason,
  String? toTag,
  String? body,
  Map<String, String> extraHeaders = const {},
}) {
  final reqRaw = request.src ?? '';
  final reqLines = reqRaw.split(crlf);
  final out = <String>[];
  out.add('SIP/2.0 $code $reason');

  final wantToTag = code >= 200 && (toTag != null && toTag.isNotEmpty);
  for (var i = 1; i < reqLines.length; i++) {
    final line = reqLines[i];
    if (line.isEmpty) break;
    final lower = line.toLowerCase();
    if (lower.startsWith('via:') ||
        lower.startsWith('via ') ||
        lower.startsWith('v:')) {
      out.add(line);
    } else if (lower.startsWith('from:') ||
        lower.startsWith('from ') ||
        lower.startsWith('f:')) {
      out.add(line);
    } else if (lower.startsWith('to:') ||
        lower.startsWith('to ') ||
        lower.startsWith('t:')) {
      if (wantToTag && !lower.contains(';tag=')) {
        out.add('$line;tag=$toTag');
      } else {
        out.add(line);
      }
    } else if (lower.startsWith('call-id:') || lower.startsWith('i:')) {
      out.add(line);
    } else if (lower.startsWith('cseq:')) {
      out.add(line);
    } else if (lower.startsWith('record-route:')) {
      // Mirror Record-Route per RFC 3261 §16.6.4 so the dialog stays in our path.
      out.add(line);
    }
  }

  for (final entry in extraHeaders.entries) {
    out.add('${entry.key}: ${entry.value}');
  }
  out.add('Content-Length: ${body == null ? 0 : body.length}');
  return joinMessage(out, body ?? '');
}
