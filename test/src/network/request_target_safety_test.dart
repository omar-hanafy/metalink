import 'package:metalink/src/network/request_target_safety.dart';
import 'package:test/test.dart';

void main() {
  group('IPv4 literal safety', () {
    test('rejects legacy decimal and hexadecimal address forms', () {
      final blocked = <String>[
        'https://127.1/',
        'https://2130706433/',
        'https://0x7f000001/',
        'https://0x7f.0.0.1/',
        'https://127.0x0.0.1/',
        'https://0x7f.0x0.0x0.0x1/',
      ];

      for (final target in blocked) {
        expect(
          unsafeTargetReason(Uri.parse(target)),
          isNotNull,
          reason: target,
        );
      }
    });

    test('does not reject ordinary host names as numeric addresses', () {
      expect(unsafeTargetReason(Uri.parse('https://example.com/')), isNull);
      expect(unsafeTargetReason(Uri.parse('https://0x.example/')), isNull);
    });

    test('uses exact special-purpose IPv4 prefix boundaries', () {
      expect(
        unsafeTargetReason(Uri.parse('https://192.0.0.1/')),
        contains('Non-public IPv4'),
      );
      expect(
        unsafeTargetReason(Uri.parse('https://192.0.2.1/')),
        contains('Non-public IPv4'),
      );
      expect(unsafeTargetReason(Uri.parse('https://192.0.1.1/')), isNull);
      expect(unsafeTargetReason(Uri.parse('https://192.0.16.1/')), isNull);
    });
  });

  group('IPv6 literal safety', () {
    test('rejects loopback in compressed and expanded forms', () {
      expect(
        unsafeTargetReason(Uri.parse('https://[::1]/')),
        contains('loopback'),
      );
      expect(
        unsafeTargetReason(Uri.parse('https://[0:0:0:0:0:0:0:1]/')),
        contains('loopback'),
      );
    });

    test('rejects mapped and compatible non-public IPv4 addresses', () {
      final blocked = <String>[
        'https://[::ffff:127.0.0.1]/',
        'https://[0:0:0:0:0:ffff:0a00:0001]/',
        'https://[::127.0.0.1]/',
        'https://[64:ff9b::192.168.1.1]/',
      ];

      for (final target in blocked) {
        expect(
          unsafeTargetReason(Uri.parse(target)),
          contains('Non-public IPv4'),
          reason: target,
        );
      }
    });

    test('rejects non-public and reserved IPv6 ranges', () {
      final blocked = <String>[
        'https://[fc00::1]/',
        'https://[fd12:3456::1]/',
        'https://[fe80::1]/',
        'https://[fec0::1]/',
        'https://[ff02::1]/',
        'https://[2001:db8::1]/',
      ];

      for (final target in blocked) {
        expect(
          unsafeTargetReason(Uri.parse(target)),
          isNotNull,
          reason: target,
        );
      }
    });

    test('allows valid global IPv6 and public mapped IPv4 addresses', () {
      final allowed = <String>[
        'https://[2001:4860:4860::8888]/',
        'https://[2606:4700:4700:0:0:0:0:1111]/',
        'https://[::ffff:8.8.8.8]/',
      ];

      for (final target in allowed) {
        expect(unsafeTargetReason(Uri.parse(target)), isNull, reason: target);
      }
    });

    test(
      'rejects malformed colon hosts instead of treating them as public',
      () {
        expect(
          unsafeIpv6LiteralReason('2001:db8:1'),
          contains('Invalid or ambiguous IPv6'),
        );
        expect(
          unsafeIpv6LiteralReason('2001:db8::1::2'),
          contains('Invalid or ambiguous IPv6'),
        );
      },
    );
  });
}
