import 'package:metalink/src/extract/url_resolver.dart';
import 'package:test/test.dart';

void main() {
  const resolver = UrlResolver();
  final base = Uri.parse('https://example.com/base/path');

  test('resolve handles null and empty', () {
    expect(resolver.resolve(base, null), isNull);
    expect(resolver.resolve(base, ''), isNull);
    expect(resolver.resolve(base, '  '), isNull);
  });

  test('resolve rejects non-http schemes and fragments', () {
    expect(resolver.resolve(base, '#frag'), isNull);
    expect(resolver.resolve(base, 'javascript:alert(1)'), isNull);
    expect(resolver.resolve(base, 'mailto:test@example.com'), isNull);
    expect(resolver.resolve(base, 'tel:123'), isNull);
    expect(resolver.resolve(base, 'data:text/plain,hi'), isNull);
  });

  test('resolve rejects hostless HTTP and HTTPS URLs', () {
    expect(resolver.resolve(base, 'http:relative'), isNull);
    expect(resolver.resolve(base, 'https:/missing-host'), isNull);
  });

  test('resolve accepts absolute and relative urls', () {
    expect(
      resolver.resolve(base, 'https://example.com/a')!.toString(),
      'https://example.com/a',
    );
    expect(
      resolver.resolve(base, '/rel')!.toString(),
      'https://example.com/rel',
    );
    expect(
      resolver.resolve(base, 'child')!.toString(),
      'https://example.com/base/child',
    );
  });

  test('resolve handles protocol-relative', () {
    expect(
      resolver.resolve(base, '//example.com/x')!.toString(),
      'https://example.com/x',
    );
  });

  test('resolveAll filters invalid entries', () {
    final result = resolver.resolveAll(base, ['a', 'mailto:x', null]);
    expect(result.length, 1);
    expect(result.first.toString(), 'https://example.com/base/a');
  });

  group('EXT-R2-5 WHATWG input cleanup', () {
    test('removes ASCII tabs and newlines anywhere', () {
      expect(
        resolver.resolve(base, 'https://exa\tmple.com/a\r\n/b'),
        Uri.parse('https://example.com/a/b'),
      );
      expect(
        resolver.resolve(base, 'img/\nx.png'),
        Uri.parse('https://example.com/base/img/x.png'),
      );
    });

    test('trims leading and trailing C0 controls and spaces', () {
      expect(
        resolver.resolve(base, '\u0000 https://example.com/a \u001f'),
        Uri.parse('https://example.com/a'),
      );
    });

    test('rejects a scheme split by a newline', () {
      expect(resolver.resolve(base, 'java\nscript:alert(1)'), isNull);
      expect(resolver.resolve(base, 'da\tta:text/plain,hi'), isNull);
    });

    test('keeps interior spaces', () {
      expect(resolver.resolve(base, 'https://example.com/a b')?.path, '/a%20b');
    });
  });
}
