import 'package:metalink/src/network/request_policy.dart';
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

  group('non-ASCII host safety', () {
    // WHATWG and UTS #46 host canonicalization maps each of these to a
    // loopback, metadata-service, or local name, but Dart's Uri keeps them
    // percent-encoded, so ASCII-only checks never see the mapped form.
    const canonicalizesToUnsafe = <String>[
      'http://１２７.０.０.１/',
      'http://127。0。0。1/',
      'http://ⓛⓞⓒⓐⓛⓗⓞⓢⓣ/',
      'http://１６９.２５４.１６９.２５４/latest/meta-data/',
    ];

    RequestTarget target(Uri uri) => RequestTarget(
      uri: uri,
      purpose: RequestPurpose.document,
      stage: RequestTargetStage.initial,
      redirectCount: 0,
    );

    test('rejects hosts that canonicalize to unsafe targets', () {
      for (final value in canonicalizesToUnsafe) {
        expect(
          unsafeTargetReason(Uri.parse(value)),
          allOf(contains('Non-ASCII'), contains('xn--')),
          reason: value,
        );
      }
    });

    test(
      'rejects Unicode and percent-encoded hosts however they are built',
      () {
        final hosts = <Uri>[
          Uri.parse('http://bücher.example/'),
          Uri(scheme: 'http', host: 'ⓛⓞⓒⓐⓛⓗⓞⓢⓣ', path: '/'),
          Uri(scheme: 'http', host: '１２７.０.０.１', path: '/'),
        ];

        for (final uri in hosts) {
          expect(unsafeTargetReason(uri), contains('xn--'), reason: '$uri');
        }
      },
    );

    test('secure policy rejects them before any request', () async {
      final policy = RequestPolicy.secure();

      for (final value in canonicalizesToUnsafe) {
        final decision = await policy.validateTarget(target(Uri.parse(value)));
        expect(decision.allowed, isFalse, reason: value);
        expect(decision.reason, contains('xn--'), reason: value);
      }
    });

    test(
      'secure policy still allows punycode and ASCII public hosts',
      () async {
        final policy = RequestPolicy.secure();
        const allowed = <String>[
          'http://xn--bcher-kva.example/',
          'https://xn--n3h.example/path',
          'https://example.com/',
          'https://sub.example.co.uk:8443/a?b=c',
        ];

        for (final value in allowed) {
          expect(unsafeTargetReason(Uri.parse(value)), isNull, reason: value);
          final decision = await policy.validateTarget(
            target(Uri.parse(value)),
          );
          expect(decision.allowed, isTrue, reason: value);
        }
      },
    );

    test('keeps the scoped IPv6 rejection for zone identifiers', () {
      expect(
        unsafeTargetReason(Uri.parse('http://[fe80::1%25eth0]/')),
        'Scoped IPv6 targets are not allowed.',
      );
    });

    test('default policy behavior is unchanged', () async {
      const policy = RequestPolicy();

      for (final value in canonicalizesToUnsafe) {
        final decision = await policy.validateTarget(target(Uri.parse(value)));
        expect(decision.allowed, isTrue, reason: value);
      }
    });
  });

  group('local host-name aliases', () {
    // Standard hosts-file aliases for loopback and link-local addresses, plus
    // the AWS metadata short name, which resolves to 169.254.169.254 on EC2.
    const aliases = <String>[
      'ip6-localhost',
      'ip6-loopback',
      'localhost.localdomain',
      'localhost4',
      'localhost6',
      'instance-data',
    ];

    test('rejects each alias, including its trailing-dot form', () {
      for (final alias in aliases) {
        for (final host in <String>[alias, '$alias.', alias.toUpperCase()]) {
          expect(
            unsafeTargetReason(Uri.parse('http://$host/')),
            'Local and internal host names are not allowed.',
            reason: host,
          );
        }
      }
    });

    test('rejects a localhost name with several trailing dots', () {
      expect(unsafeTargetReason(Uri.parse('http://localhost../')), isNotNull);
    });

    test('still allows public names that merely contain an alias', () {
      const allowed = <String>[
        'https://localhost4.example.com/',
        'https://instance-data.example.com/',
        'https://my-ip6-localhost.example/',
      ];
      for (final value in allowed) {
        expect(unsafeTargetReason(Uri.parse(value)), isNull, reason: value);
      }
    });
  });
}
