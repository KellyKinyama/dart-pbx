/// Minimal RFC 3261 message model — enough to talk to the dart-pbx server.
///
/// A [SipMessage] is either a request (has [method] + [requestUri]) or a
/// response (has [statusCode] + [reasonPhrase]). Headers are kept as a list
/// of (name, value) pairs because SIP allows duplicates (Via, Route, ...).
library;

class SipMessage {
  SipMessage._({
    this.method,
    this.requestUri,
    this.statusCode,
    this.reasonPhrase,
    required this.headers,
    this.body = '',
  });

  /// Build a request.
  factory SipMessage.request(
    String method,
    String requestUri, {
    List<MapEntry<String, String>>? headers,
    String body = '',
  }) => SipMessage._(
    method: method,
    requestUri: requestUri,
    headers: headers ?? <MapEntry<String, String>>[],
    body: body,
  );

  /// Build a response.
  factory SipMessage.response({
    required int code,
    required String reason,
    List<MapEntry<String, String>>? headers,
    String body = '',
  }) => SipMessage._(
    statusCode: code,
    reasonPhrase: reason,
    headers: headers ?? <MapEntry<String, String>>[],
    body: body,
  );

  /// Parse a wire message.
  factory SipMessage.parse(String raw) {
    final eoh = raw.indexOf('\r\n\r\n');
    final headPart = eoh < 0 ? raw : raw.substring(0, eoh);
    final body = eoh < 0 ? '' : raw.substring(eoh + 4);
    final lines = headPart.split('\r\n');
    if (lines.isEmpty) {
      throw const FormatException('empty SIP message');
    }
    final start = lines.first;
    final headers = <MapEntry<String, String>>[];
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final name = line.substring(0, colon).trim();
      var value = line.substring(colon + 1);
      if (value.isNotEmpty && (value[0] == ' ' || value[0] == '\t')) {
        value = value.substring(1);
      }
      headers.add(MapEntry(name, value));
    }

    if (start.startsWith('SIP/2.0 ')) {
      final rest = start.substring(8);
      final sp = rest.indexOf(' ');
      final code = int.tryParse(sp < 0 ? rest : rest.substring(0, sp)) ?? 0;
      final reason = sp < 0 ? '' : rest.substring(sp + 1);
      return SipMessage._(
        statusCode: code,
        reasonPhrase: reason,
        headers: headers,
        body: body,
      );
    }
    final parts = start.split(' ');
    if (parts.length < 3) {
      throw FormatException('bad start line: $start');
    }
    return SipMessage._(
      method: parts[0],
      requestUri: parts.sublist(1, parts.length - 1).join(' '),
      headers: headers,
      body: body,
    );
  }

  final String? method;
  final String? requestUri;
  final int? statusCode;
  final String? reasonPhrase;
  final List<MapEntry<String, String>> headers;
  String body;

  bool get isRequest => method != null;
  bool get isResponse => statusCode != null;

  // -------- header helpers --------

  String? header(String name) {
    final lower = name.toLowerCase();
    for (final h in headers) {
      if (h.key.toLowerCase() == lower) return h.value;
    }
    return null;
  }

  List<String> headersAll(String name) {
    final lower = name.toLowerCase();
    return [
      for (final h in headers)
        if (h.key.toLowerCase() == lower) h.value,
    ];
  }

  void setHeader(String name, String value) {
    final lower = name.toLowerCase();
    for (var i = 0; i < headers.length; i++) {
      if (headers[i].key.toLowerCase() == lower) {
        headers[i] = MapEntry(name, value);
        return;
      }
    }
    headers.add(MapEntry(name, value));
  }

  void addHeader(String name, String value) {
    headers.add(MapEntry(name, value));
  }

  void removeHeader(String name) {
    final lower = name.toLowerCase();
    headers.removeWhere((h) => h.key.toLowerCase() == lower);
  }

  /// Returns the dialog identifier (Call-ID + local-tag + remote-tag).
  String? get callId => header('Call-ID') ?? header('i');

  String? get fromTag => _paramOf(header('From') ?? header('f'), 'tag');
  String? get toTag => _paramOf(header('To') ?? header('t'), 'tag');

  /// Returns "<seq> <method>".
  String? get cseq => header('CSeq');

  int? get cseqNumber {
    final v = cseq;
    if (v == null) return null;
    final sp = v.indexOf(' ');
    return int.tryParse(sp < 0 ? v : v.substring(0, sp));
  }

  String? get cseqMethod {
    final v = cseq;
    if (v == null) return null;
    final sp = v.indexOf(' ');
    return sp < 0 ? null : v.substring(sp + 1).trim();
  }

  /// Serialise back to the wire.
  String encode() {
    final sb = StringBuffer();
    if (isRequest) {
      sb.write('$method $requestUri SIP/2.0\r\n');
    } else {
      sb.write('SIP/2.0 $statusCode $reasonPhrase\r\n');
    }
    final hasContentLength = headers.any(
      (h) => h.key.toLowerCase() == 'content-length',
    );
    for (final h in headers) {
      sb.write('${h.key}: ${h.value}\r\n');
    }
    if (!hasContentLength) {
      sb.write('Content-Length: ${body.length}\r\n');
    }
    sb.write('\r\n');
    sb.write(body);
    return sb.toString();
  }

  @override
  String toString() => encode();
}

String? _paramOf(String? headerValue, String name) {
  if (headerValue == null) return null;
  final lower = name.toLowerCase();
  for (final part in headerValue.split(';')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    if (part.substring(0, eq).trim().toLowerCase() == lower) {
      var v = part.substring(eq + 1).trim();
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      return v;
    }
  }
  return null;
}

/// Parses a comma-separated `name=value` parameter list (e.g. an
/// Authorization or WWW-Authenticate header body, minus the scheme prefix).
Map<String, String> parseAuthHeader(String value) {
  var s = value.trim();
  final lower = s.toLowerCase();
  if (lower.startsWith('digest ')) {
    s = s.substring(7).trim();
  } else if (lower == 'digest') {
    return {};
  }
  final out = <String, String>{};
  var i = 0;
  while (i < s.length) {
    while (i < s.length && (s[i] == ' ' || s[i] == ',' || s[i] == '\t')) {
      i++;
    }
    if (i >= s.length) break;
    final eq = s.indexOf('=', i);
    if (eq < 0) break;
    final name = s.substring(i, eq).trim().toLowerCase();
    var j = eq + 1;
    String val;
    if (j < s.length && s[j] == '"') {
      final end = s.indexOf('"', j + 1);
      if (end < 0) break;
      val = s.substring(j + 1, end);
      j = end + 1;
    } else {
      var end = j;
      while (end < s.length && s[end] != ',') {
        end++;
      }
      val = s.substring(j, end).trim();
      j = end;
    }
    out[name] = val;
    i = j;
  }
  return out;
}

/// Returns the URI from a name-addr or addr-spec header value (From, To,
/// Contact). Strips display name and surrounding angle brackets and any
/// header parameters after the URI.
String extractUri(String headerValue) {
  final v = headerValue.trim();
  final lt = v.indexOf('<');
  if (lt >= 0) {
    final gt = v.indexOf('>', lt + 1);
    if (gt > lt) return v.substring(lt + 1, gt);
  }
  final semi = v.indexOf(';');
  return semi < 0 ? v : v.substring(0, semi);
}
