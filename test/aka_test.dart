// Tests for the IMS AKAv1-MD5 (RFC 3310) layer built on top of Milenage.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_pbx/ims/aka.dart';
import 'package:dart_pbx/ims/milenage.dart';
import 'package:test/test.dart';

void main() {
  // Reuse TS 35.207 Test Set 1 — gives us deterministic XRES/AUTN to play
  // the full RFC 3310 challenge/response against.
  final k = hexToBytes('465b5ce8b199b49faa5f0a2ee238a6bc');
  final rand = hexToBytes('23553cbe9637a89d218ae64dae47bf35');
  final sqn = hexToBytes('ff9bb4d0b607');
  final amf = hexToBytes('b9b9');
  final opc = hexToBytes('cd63cb71954a9f4e48a5994e37a02baf');

  // Expected outputs from TS 35.207 Test Set 1.
  const expectedRes = 'a54211d5e3ba50bf';
  // AUTN = (SQN XOR AK) || AMF || MAC-A
  // AK    = aa689c648370,  SQN XOR AK = 55f328b43577
  // AMF   = b9b9
  // MAC-A = 4a9ffac354dfafb3
  const expectedAutn = '55f328b43577b9b94a9ffac354dfafb3';

  group('AuthVector.generate', () {
    test('produces TS 35.207 RES and matching AUTN', () {
      final av = AuthVector.generate(
        k: k,
        opc: opc,
        rand: rand,
        sqn: sqn,
        amf: amf,
      );
      expect(bytesToHex(av.xres), expectedRes);
      expect(bytesToHex(av.autn), expectedAutn);
      expect(av.rand.length, 16);
      expect(av.ck.length, 16);
      expect(av.ik.length, 16);
    });

    test('nonce is base64( RAND || AUTN )', () {
      final av = AuthVector.generate(
        k: k,
        opc: opc,
        rand: rand,
        sqn: sqn,
        amf: amf,
      );
      final raw = base64.decode(av.nonceB64);
      expect(raw.length, 32);
      expect(
          bytesToHex(Uint8List.fromList(raw.sublist(0, 16))), bytesToHex(rand));
      expect(bytesToHex(Uint8List.fromList(raw.sublist(16, 32))), expectedAutn);
    });
  });

  group('AkaAuth challenge / verify roundtrip', () {
    test('valid response is accepted', () {
      final aka = AkaAuth(realm: 'ims.example.com');
      final av = AuthVector.generate(
        k: k,
        opc: opc,
        rand: rand,
        sqn: sqn,
        amf: amf,
      );
      final challenge = aka.challengeHeaderValue(av);

      // Parse out the nonce we just put on the wire.
      final nonce = _extract(challenge, 'nonce');
      expect(nonce, isNotNull);

      // UE side: build the response per RFC 3310 §3.4 / RFC 2617.
      const impi = 'alice@ims.example.com';
      const uri = 'sip:ims.example.com';
      const method = 'REGISTER';
      const nc = '00000001';
      const cnonce = '0a4f113b';
      const qop = 'auth';

      final ha1Input = BytesBuilder()
        ..add(utf8.encode('$impi:ims.example.com:'))
        ..add(av.xres);
      final ha1 = md5.convert(ha1Input.toBytes()).toString();
      final ha2 = md5.convert(utf8.encode('$method:$uri')).toString();
      final response = md5
          .convert(utf8.encode('$ha1:$nonce:$nc:$cnonce:$qop:$ha2'))
          .toString();

      final authHeader = 'Digest username="$impi", realm="ims.example.com", '
          'nonce="$nonce", uri="$uri", response="$response", '
          'algorithm=AKAv1-MD5, cnonce="$cnonce", qop=$qop, nc=$nc';

      final result = aka.verify(headerValue: authHeader, method: method);
      expect(result.result, AkaResult.ok);
      expect(result.impi, impi);
      expect(result.av, isNotNull);
    });

    test('wrong RES is rejected', () {
      final aka = AkaAuth(realm: 'ims.example.com');
      final av = AuthVector.generate(
        k: k,
        opc: opc,
        rand: rand,
        sqn: sqn,
        amf: amf,
      );
      final challenge = aka.challengeHeaderValue(av);
      final nonce = _extract(challenge, 'nonce')!;

      const impi = 'alice@ims.example.com';
      const uri = 'sip:ims.example.com';
      const method = 'REGISTER';
      const nc = '00000001';
      const cnonce = '0a4f113b';

      // Pretend the SIM returned a bogus RES.
      final badRes = Uint8List(8);
      final ha1Input = BytesBuilder()
        ..add(utf8.encode('$impi:ims.example.com:'))
        ..add(badRes);
      final ha1 = md5.convert(ha1Input.toBytes()).toString();
      final ha2 = md5.convert(utf8.encode('$method:$uri')).toString();
      final response = md5
          .convert(utf8.encode('$ha1:$nonce:$nc:$cnonce:auth:$ha2'))
          .toString();

      final authHeader = 'Digest username="$impi", realm="ims.example.com", '
          'nonce="$nonce", uri="$uri", response="$response", '
          'algorithm=AKAv1-MD5, cnonce="$cnonce", qop=auth, nc=$nc';

      final result = aka.verify(headerValue: authHeader, method: method);
      expect(result.result, AkaResult.failed);
    });

    test('successful auth consumes the nonce (single-use AV)', () {
      final aka = AkaAuth(realm: 'ims.example.com');
      final av = AuthVector.generate(
        k: k,
        opc: opc,
        rand: rand,
        sqn: sqn,
        amf: amf,
      );
      final challenge = aka.challengeHeaderValue(av);
      final nonce = _extract(challenge, 'nonce')!;

      const impi = 'alice@ims.example.com';
      const uri = 'sip:ims.example.com';
      const method = 'REGISTER';
      const nc = '00000001';
      const cnonce = '0a4f113b';

      final ha1Input = BytesBuilder()
        ..add(utf8.encode('$impi:ims.example.com:'))
        ..add(av.xres);
      final ha1 = md5.convert(ha1Input.toBytes()).toString();
      final ha2 = md5.convert(utf8.encode('$method:$uri')).toString();
      final response = md5
          .convert(utf8.encode('$ha1:$nonce:$nc:$cnonce:auth:$ha2'))
          .toString();

      final authHeader = 'Digest username="$impi", realm="ims.example.com", '
          'nonce="$nonce", uri="$uri", response="$response", '
          'algorithm=AKAv1-MD5, cnonce="$cnonce", qop=auth, nc=$nc';

      expect(aka.verify(headerValue: authHeader, method: method).result,
          AkaResult.ok);
      // Replay should now fail because the nonce was consumed.
      expect(aka.verify(headerValue: authHeader, method: method).result,
          AkaResult.failed);
    });

    test('auts parameter triggers resync flow', () {
      final aka = AkaAuth(realm: 'ims.example.com');
      final av = AuthVector.generate(
        k: k,
        opc: opc,
        rand: rand,
        sqn: sqn,
        amf: amf,
      );
      final challenge = aka.challengeHeaderValue(av);
      final nonce = _extract(challenge, 'nonce')!;

      // 14-byte AUTS = (SQN_MS XOR AK*) || MAC-S.
      final autsBytes = Uint8List.fromList(List<int>.generate(14, (i) => i));
      final autsB64 = base64.encode(autsBytes);

      final authHeader =
          'Digest username="alice@ims.example.com", realm="ims.example.com", '
          'nonce="$nonce", uri="sip:ims.example.com", '
          'algorithm=AKAv1-MD5, auts="$autsB64"';

      final result = aka.verify(headerValue: authHeader, method: 'REGISTER');
      expect(result.result, AkaResult.resync);
      expect(result.auts, isNotNull);
      expect(bytesToHex(result.auts!), bytesToHex(autsBytes));
      expect(bytesToHex(result.rand!), bytesToHex(rand));
    });
  });
}

/// Pulls the value of a quoted parameter out of a `Digest ...` header.
String? _extract(String header, String name) {
  final m = RegExp('$name="([^"]*)"').firstMatch(header);
  return m?.group(1);
}
