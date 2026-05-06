import 'package:dart_pbx/proxy/sip_helpers.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('generators', () {
    test('generateBranch contains the magic cookie and is reasonably random',
        () {
      final a = generateBranch();
      final b = generateBranch();
      expect(a, startsWith('z9hG4bK'));
      expect(b, startsWith('z9hG4bK'));
      expect(a, isNot(equals(b)));
      expect(a.length, greaterThan('z9hG4bK'.length + 8));
    });

    test('generateTag and generateCallId differ each call', () {
      expect(generateTag(), isNot(equals(generateTag())));
      expect(generateCallId('host'), endsWith('@host'));
      expect(generateCallId('h'), isNot(equals(generateCallId('h'))));
    });
  });

  group('splitMessage / joinMessage', () {
    test('round-trip preserves headers and body verbatim', () {
      const body = 'v=0\r\no=- 1 1 IN IP4 1.2.3.4\r\n';
      final raw = wire([
        'INVITE sip:bob@example.com SIP/2.0',
        'Via: SIP/2.0/UDP 1.2.3.4:5060;branch=z9hG4bK-1',
        'Content-Length: ${body.length}',
      ]).replaceFirst('\r\n\r\n', '\r\n\r\n$body');

      final parts = splitMessage(raw);
      expect(parts.headers.first, 'INVITE sip:bob@example.com SIP/2.0');
      expect(parts.body, body);

      final back = joinMessage(parts.headers, parts.body);
      expect(back.contains(body), isTrue);
      // Header block ends with CRLF CRLF before the body.
      expect(back.contains('\r\n\r\n$body'), isTrue);
    });

    test('handles a message with no body', () {
      final raw = wire(['OPTIONS sip:x SIP/2.0', 'Via: SIP/2.0/UDP h:5060']);
      final parts = splitMessage(raw);
      expect(parts.body, isEmpty);
    });
  });

  group('Max-Forwards', () {
    test('decrements existing value', () {
      final headers = [
        'INVITE sip:x SIP/2.0',
        'Max-Forwards: 70',
      ];
      expect(decrementMaxForwards(headers), 69);
      expect(headers[1], 'Max-Forwards: 69');
    });

    test('returns null on underflow (would go below 0)', () {
      final headers = ['INVITE sip:x SIP/2.0', 'Max-Forwards: 0'];
      expect(decrementMaxForwards(headers), isNull);
    });

    test('inserts default 70 when missing', () {
      final headers = ['INVITE sip:x SIP/2.0'];
      expect(decrementMaxForwards(headers), 70);
      expect(headers, contains('Max-Forwards: 70'));
    });
  });

  group('Via manipulation', () {
    test('prependVia inserts at index 1, popTopVia removes the topmost', () {
      final headers = [
        'INVITE sip:x SIP/2.0',
        'Via: SIP/2.0/UDP downstream:5060;branch=z9hG4bK-down',
        'From: <sip:a@b>;tag=1',
      ];
      prependVia(headers, 'Via: SIP/2.0/UDP self:5060;branch=z9hG4bK-self');
      expect(headers[1], contains('self:5060'));
      expect(headers[2], contains('downstream:5060'));

      final popped = popTopVia(headers);
      expect(popped, contains('self:5060'));
      expect(headers[1], contains('downstream:5060'));
    });
  });

  group('Record-Route / Route', () {
    test('addRecordRoute prepends after the request line', () {
      final headers = ['INVITE sip:x SIP/2.0', 'Via: SIP/2.0/UDP h:5060'];
      addRecordRoute(headers, 'sip:proxy:5060;lr');
      expect(headers[1], 'Record-Route: <sip:proxy:5060;lr>');
    });

    test('readRecordRoutes / readRoutes parse multiple values, ignore brackets',
        () {
      final headers = [
        'INVITE sip:x SIP/2.0',
        'Record-Route: <sip:p1:5060;lr>, <sip:p2:5060;lr>',
        'Route: <sip:r1:5060;lr>',
        'Route: <sip:r2:5060;lr>, <sip:r3:5060;lr>',
      ];
      expect(readRecordRoutes(headers), ['sip:p1:5060;lr', 'sip:p2:5060;lr']);
      expect(readRoutes(headers),
          ['sip:r1:5060;lr', 'sip:r2:5060;lr', 'sip:r3:5060;lr']);
    });

    test('consumeTopRouteIfSelf removes only when host:port matches', () {
      final headers = [
        'BYE sip:x SIP/2.0',
        'Route: <sip:proxy:5060;lr>, <sip:next:5060;lr>',
      ];
      expect(consumeTopRouteIfSelf(headers, 'proxy', 5060), isTrue);
      // First entry consumed; second remains in place.
      expect(headers[1], contains('next:5060'));

      // Non-matching Route is left untouched.
      expect(consumeTopRouteIfSelf(headers, 'someone-else', 9999), isFalse);
      expect(headers[1], contains('next:5060'));
    });

    test('consumeTopRouteIfSelf removes the whole header when it was the last',
        () {
      final headers = [
        'BYE sip:x SIP/2.0',
        'Route: <sip:proxy:5060;lr>',
        'Via: SIP/2.0/UDP h:5060',
      ];
      expect(consumeTopRouteIfSelf(headers, 'proxy', 5060), isTrue);
      expect(headers.any((h) => h.toLowerCase().startsWith('route:')), isFalse);
    });
  });

  group('buildResponse', () {
    test('mirrors Via/From/To/Call-ID/CSeq and adds To-tag for 2xx', () {
      final req = parse(wire([
        'INVITE sip:bob@example.com SIP/2.0',
        'Via: SIP/2.0/UDP a:5060;branch=z9hG4bK-1',
        'From: <sip:alice@example.com>;tag=alice-tag',
        'To: <sip:bob@example.com>',
        'Call-ID: cid-1',
        'CSeq: 1 INVITE',
        'Content-Length: 0',
      ]));
      final raw = buildResponse(req, code: 200, reason: 'OK', toTag: 'srv-tag');
      expect(raw, startsWith('SIP/2.0 200 OK\r\n'));
      expect(raw, contains('Via: SIP/2.0/UDP a:5060'));
      expect(raw, contains('From: <sip:alice@example.com>;tag=alice-tag'));
      expect(raw, contains('To: <sip:bob@example.com>;tag=srv-tag'));
      expect(raw, contains('Call-ID: cid-1'));
      expect(raw, contains('CSeq: 1 INVITE'));
      expect(raw, contains('Content-Length: 0'));
    });

    test('omits To-tag for 1xx responses', () {
      final req = parse(wire([
        'INVITE sip:bob@example.com SIP/2.0',
        'Via: SIP/2.0/UDP a:5060;branch=z9hG4bK-1',
        'From: <sip:alice@example.com>;tag=t',
        'To: <sip:bob@example.com>',
        'Call-ID: cid-2',
        'CSeq: 1 INVITE',
        'Content-Length: 0',
      ]));
      final raw = buildResponse(req,
          code: 100, reason: 'Trying', toTag: 'should-not-appear');
      expect(raw, contains('To: <sip:bob@example.com>'));
      expect(raw, isNot(contains('should-not-appear')));
    });

    test('extraHeaders are included verbatim and Content-Length matches body',
        () {
      final req = parse(wire([
        'OPTIONS sip:proxy SIP/2.0',
        'Via: SIP/2.0/UDP a:5060;branch=z9hG4bK-1',
        'From: <sip:a@b>;tag=t',
        'To: <sip:proxy>',
        'Call-ID: cid-3',
        'CSeq: 1 OPTIONS',
        'Content-Length: 0',
      ]));
      final raw = buildResponse(
        req,
        code: 423,
        reason: 'Interval Too Brief',
        toTag: 'tag',
        extraHeaders: {'Min-Expires': '60'},
        body: 'hello',
      );
      expect(raw, contains('Min-Expires: 60'));
      expect(raw, contains('Content-Length: 5'));
      expect(raw, endsWith('hello'));
    });
  });

  group('CSeq / dialog helpers', () {
    test('cseqNumber and cseqMethod extract their fields', () {
      final m = parse(wire([
        'INVITE sip:b@example SIP/2.0',
        'Via: SIP/2.0/UDP h:5060',
        'CSeq: 42 INVITE',
        'Call-ID: c',
        'From: <sip:a@example>;tag=1',
        'To: <sip:b@example>',
        'Content-Length: 0',
      ]));
      expect(cseqNumber(m), 42);
      expect(cseqMethod(m), 'INVITE');
    });

    test('isInDialog requires both From-tag and To-tag', () {
      final initial = parse(wire([
        'INVITE sip:b@example SIP/2.0',
        'Via: SIP/2.0/UDP h:5060',
        'CSeq: 1 INVITE',
        'Call-ID: c',
        'From: <sip:a@example>;tag=1',
        'To: <sip:b@example>',
        'Content-Length: 0',
      ]));
      final inDialog = parse(wire([
        'BYE sip:b@example SIP/2.0',
        'Via: SIP/2.0/UDP h:5060',
        'CSeq: 2 BYE',
        'Call-ID: c',
        'From: <sip:a@example>;tag=1',
        'To: <sip:b@example>;tag=2',
        'Content-Length: 0',
      ]));
      expect(isInDialog(initial), isFalse);
      expect(isInDialog(inDialog), isTrue);
    });
  });
}
