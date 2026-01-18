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

  test('resolve accepts absolute and relative urls', () {
    expect(resolver.resolve(base, 'https://example.com/a')!.toString(),
        'https://example.com/a');
    expect(
        resolver.resolve(base, '/rel')!.toString(), 'https://example.com/rel');
    expect(resolver.resolve(base, 'child')!.toString(),
        'https://example.com/base/child');
  });

  test('resolve handles protocol-relative', () {
    expect(resolver.resolve(base, '//example.com/x')!.toString(),
        'https://example.com/x');
  });

  test('resolveAll filters invalid entries', () {
    final result = resolver.resolveAll(base, ['a', 'mailto:x', null]);
    expect(result.length, 1);
    expect(result.first.toString(), 'https://example.com/base/a');
  });
}
