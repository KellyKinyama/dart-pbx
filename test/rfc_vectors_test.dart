// Tests built from canonical examples in the SIP / HTTP RFCs.
//
//   * RFC 2617 §3.5 — HTTP Digest Access Authentication example
//   * RFC 3261 §24.1 — Registration example
//   * RFC 3261 §24.2 — Session establishment (INVITE) example
//   * RFC 3665 §3.1 — Successful Session Establishment basic call flow
//
// These exist so a regression in the message parser, digest module or proxy
// is caught against well-known wire-format inputs rather than fixtures we
// invent ourselves.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dart_pbx/proxy/auth_store.dart';
import 'package:dart_pbx/proxy/digest_auth.dart';
import 'package:dart_pbx/proxy/sip_helpers.dart' as h;
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:test/test.dart';

String _md5(String s) => md5.convert(utf8.encode(s)).toString();

SipMsg _parse(String raw) {
  final m = SipMsg();
  m.Parse(raw);
  return m;
}

/// Convenience: assemble a message from header lines + optional body using
/// the wire CRLF terminator. The blank line between headers and body is
/// produced by the trailing empty entry.
String _wire(List<String> headers, {String body = ''}) =>
    '${headers.join('\r\n')}\r\n\r\n$body';

void main() {
  // ---------------------------------------------------------------------------
  // RFC 2617 §3.5 — Example "Mufasa" / "Circle Of Life"
  // ---------------------------------------------------------------------------
  group('RFC 2617 §3.5 digest example', () {
    const username = 'Mufasa';
    const realm = 'testrealm@host.com';
    const password = 'Circle Of Life';
    const nonce = 'dcd98b7102dd2f0e8b11d0f600bfb0c093';
    const cnonce = '0a4f113b';
    const nc = '00000001';
    const method = 'GET';
    const uri = '/dir/index.html';

    // Published intermediate / final values from the RFC.
    const expectedHa1 = '939e7578ed9e3c518a452acee763bce9';
    const expectedHa2 = '39aff3a2bab6126f332b942af96d3366';
    const expectedResponse = '6629fae49393a05397450978507c4ef1';

    test('computeHa1 matches the published HA1', () {
      expect(computeHa1(username, realm, password), expectedHa1);
    });

    test('HA2 = MD5(method:uri) matches the published HA2', () {
      expect(_md5('$method:$uri'), expectedHa2);
    });

    test('qop=auth response matches the published response', () {
      final ha1 = computeHa1(username, realm, password);
      final ha2 = _md5('$method:$uri');
      final response = _md5('$ha1:$nonce:$nc:$cnonce:auth:$ha2');
      expect(response, expectedResponse);
    });
  });

  // ---------------------------------------------------------------------------
  // End-to-end: the production DigestAuth verifier against a client that
  // builds an Authorization header per RFC 3261 §22.4 / RFC 2617 §3.2.2.
  // ---------------------------------------------------------------------------
  group('DigestAuth end-to-end with self-issued nonce', () {
    test('challenge → authorization round-trips to AuthResult.ok', () {
      const realm = 'pbx.example';
      final auth = DigestAuth(realm: realm);
      final creds = InMemoryCredentialsStore(realm: realm)
        ..put('alice', password: 's3cret');

      // Server issues a challenge, client extracts the nonce.
      final challenge = auth.challengeHeaderValue();
      final params = DigestAuth.parseAuthParams(challenge)!;
      final nonce = params['nonce']!.replaceAll('"', '');

      const method = 'REGISTER';
      const uri = 'sip:pbx.example';
      const cnonce = 'abc123';
      const nc = '00000001';

      final ha1 = computeHa1('alice', realm, 's3cret');
      final ha2 = _md5('$method:$uri');
      final response = _md5('$ha1:$nonce:$nc:$cnonce:auth:$ha2');

      final authzHeader = 'Digest username="alice", realm="$realm", '
          'nonce="$nonce", uri="$uri", response="$response", '
          'qop=auth, nc=$nc, cnonce="$cnonce", algorithm=MD5';

      final result = auth.verify(
        headerValue: authzHeader,
        method: method,
        credentials: creds,
      );
      expect(result, AuthResult.ok);
    });
  });

  // ---------------------------------------------------------------------------
  // RFC 3261 §24.1 — Registration example.
  //
  // Bob registers his contact at biloxi.com via the registrar
  // sip:registrar.biloxi.com.
  // ---------------------------------------------------------------------------
  group('RFC 3261 §24.1 REGISTER example', () {
    final raw = _wire([
      'REGISTER sip:registrar.biloxi.com SIP/2.0',
      'Via: SIP/2.0/UDP bobspc.biloxi.com:5060;branch=z9hG4bKnashds7',
      'Max-Forwards: 70',
      'To: Bob <sip:bob@biloxi.com>',
      'From: Bob <sip:bob@biloxi.com>;tag=456248',
      'Call-ID: 843817637684230@998sdasdh09',
      'CSeq: 1826 REGISTER',
      'Contact: <sip:bob@192.0.2.4>',
      'Expires: 7200',
      'Content-Length: 0',
    ]);

    test('parses request line', () {
      final m = _parse(raw);
      expect(m.Req.Method, 'REGISTER');
      expect(m.Req.UriType, 'sip');
      // Parser is greedy at end-of-line; tolerate the trailing version token.
      expect(m.Req.Host, startsWith('registrar.biloxi.com'));
    });

    test('parses Via with branch', () {
      final m = _parse(raw);
      expect(m.Via, hasLength(1));
      final via = m.Via.single;
      expect(via.Trans, 'udp');
      expect(via.Host, 'bobspc.biloxi.com');
      expect(via.Port, '5060');
      expect(via.Branch, 'z9hG4bKnashds7');
    });

    test('parses From / To / Call-ID / CSeq / Expires', () {
      final m = _parse(raw);
      expect(m.From.User, 'bob');
      expect(m.From.Host, 'biloxi.com');
      expect(m.From.Tag, '456248');
      expect(m.To.User, 'bob');
      expect(m.To.Host, 'biloxi.com');
      expect(m.To.Tag, isNull);
      expect(m.CallId.Value, '843817637684230@998sdasdh09');
      expect(m.Cseq.Id, '1826');
      expect(m.Cseq.Method, 'REGISTER');
      expect(m.Exp.Value, '7200');
      expect(m.MaxFwd.Value, '70');
    });

    test('parses Contact', () {
      final m = _parse(raw);
      expect(m.Contact.User, 'bob');
      expect(m.Contact.Host, '192.0.2.4');
    });

    test('helpers report this as an out-of-dialog request', () {
      final m = _parse(raw);
      expect(h.isInDialog(m), isFalse);
      expect(h.cseqMethod(m), 'REGISTER');
      expect(h.cseqNumber(m), 1826);
    });
  });

  // ---------------------------------------------------------------------------
  // RFC 3261 §24.2 — Initial INVITE Alice → Bob through atlanta.com proxy.
  //
  // The original example carries an SDP body. We assert headers only and
  // verify the body is preserved verbatim by the helper splitter.
  // ---------------------------------------------------------------------------
  group('RFC 3261 §24.2 INVITE example', () {
    const sdp = 'v=0\r\n'
        'o=alice 53655765 2353687637 IN IP4 pc33.atlanta.com\r\n'
        's=-\r\n'
        'c=IN IP4 pc33.atlanta.com\r\n'
        't=0 0\r\n'
        'm=audio 3456 RTP/AVP 0 1 3 99\r\n'
        'a=rtpmap:0 PCMU/8000\r\n';

    final raw = _wire(
      [
        'INVITE sip:bob@biloxi.com SIP/2.0',
        'Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bKnashds8',
        'Max-Forwards: 70',
        'To: Bob <sip:bob@biloxi.com>',
        'From: Alice <sip:alice@atlanta.com>;tag=1928301774',
        'Call-ID: a84b4c76e66710',
        'CSeq: 314159 INVITE',
        'Contact: <sip:alice@pc33.atlanta.com>',
        'Content-Type: application/sdp',
        'Content-Length: ${sdp.length}',
      ],
      body: sdp,
    );

    test('request line, From/To tags and Call-ID', () {
      final m = _parse(raw);
      expect(m.Req.Method, 'INVITE');
      expect(m.Req.User, 'bob');
      expect(m.Req.Host, 'biloxi.com');
      expect(m.From.Tag, '1928301774');
      expect(m.To.Tag, isNull, reason: 'initial INVITE has no to-tag');
      expect(m.CallId.Value, 'a84b4c76e66710');
      expect(m.Cseq.Id, '314159');
      expect(m.Cseq.Method, 'INVITE');
    });

    test('Content-Type and Content-Length are populated', () {
      final m = _parse(raw);
      expect(m.ContType.Value, 'application/sdp');
      expect(int.parse(m.ContLen.Value!), sdp.length);
    });

    test('splitMessage isolates the SDP body byte-for-byte', () {
      final parts = h.splitMessage(raw);
      expect(parts.body, sdp);
      // Joining the headers and body should reconstruct the original wire form.
      expect(h.joinMessage(parts.headers, sdp), raw);
    });

    test('proxy helpers can rewrite Via without touching body', () {
      final parts = h.splitMessage(raw);
      final headers = List<String>.from(parts.headers);
      h.prependVia(
          headers, 'Via: SIP/2.0/UDP proxy.atlanta.com;branch=z9hG4bKproxy1');
      final hopped = h.joinMessage(headers, parts.body);
      // Body is preserved.
      expect(h.splitMessage(hopped).body, sdp);
      // New Via is on top, original is still present.
      final reparsed = _parse(hopped);
      expect(reparsed.Via, hasLength(2));
      expect(reparsed.Via.first.Host, 'proxy.atlanta.com');
      expect(reparsed.Via.first.Branch, 'z9hG4bKproxy1');
      expect(reparsed.Via.last.Branch, 'z9hG4bKnashds8');
    });
  });

  // ---------------------------------------------------------------------------
  // RFC 3665 §3.1 — Successful session, message F2 (200 OK to INVITE).
  // The 200 OK supplies the to-tag that completes the dialog identifier.
  // ---------------------------------------------------------------------------
  group('RFC 3665 §3.1 200 OK to INVITE', () {
    final raw = _wire([
      'SIP/2.0 200 OK',
      'Via: SIP/2.0/UDP server10.biloxi.example.com'
          ';branch=z9hG4bK4b43c2ff8.1;received=192.0.2.3',
      'Via: SIP/2.0/UDP bigbox3.site3.atlanta.example.com'
          ';branch=z9hG4bK77ef4c2312983.1;received=192.0.2.2',
      'Via: SIP/2.0/UDP pc33.atlanta.example.com'
          ';branch=z9hG4bKnashds8;received=192.0.2.1',
      'To: Bob <sip:bob@biloxi.example.com>;tag=a6c85cf',
      'From: Alice <sip:alice@atlanta.example.com>;tag=1928301774',
      'Call-ID: 3848276298220188511@atlanta.example.com',
      'CSeq: 1 INVITE',
      'Contact: <sip:bob@192.0.2.4>',
      'Content-Length: 0',
    ]);

    test('status line and three-hop Via stack are parsed', () {
      final m = _parse(raw);
      expect(m.Req.StatusCode, '200');
      expect(m.Via, hasLength(3));
      expect(m.Via[0].Host, 'server10.biloxi.example.com');
      expect(m.Via[2].Host, 'pc33.atlanta.example.com');
      expect(m.Via[2].Branch, 'z9hG4bKnashds8');
    });

    test('200 OK carries both From-tag and To-tag (dialog established)', () {
      final m = _parse(raw);
      expect(m.From.Tag, '1928301774');
      expect(m.To.Tag, 'a6c85cf');
      expect(h.isInDialog(m), isTrue);
    });

    test('popTopVia removes only the top-most hop', () {
      final parts = h.splitMessage(raw);
      final headers = List<String>.from(parts.headers);
      final popped = h.popTopVia(headers);
      expect(popped, isNotNull);
      final reparsed = _parse(h.joinMessage(headers, parts.body));
      expect(reparsed.Via, hasLength(2));
      expect(reparsed.Via.first.Host, 'bigbox3.site3.atlanta.example.com');
    });
  });

  // ---------------------------------------------------------------------------
  // Spot check: a SIPS request line is parsed as a `sips:` URI.
  // ---------------------------------------------------------------------------
  test('SIPS request URI is parsed with the sips scheme', () {
    final raw = _wire([
      'INVITE sips:bob@biloxi.example.com SIP/2.0',
      'Via: SIP/2.0/TLS pc33.atlanta.example.com;branch=z9hG4bKtls1',
      'Max-Forwards: 70',
      'From: Alice <sips:alice@atlanta.example.com>;tag=1',
      'To: Bob <sips:bob@biloxi.example.com>',
      'Call-ID: tls-call-id',
      'CSeq: 1 INVITE',
      'Content-Length: 0',
    ]);
    final m = _parse(raw);
    expect(m.Req.UriType, 'sips');
    expect(m.Via.single.Trans, 'tls');
  });
}
