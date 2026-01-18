import 'package:metalink/src/cache/cache_key.dart';
import 'package:test/test.dart';

void main() {
  test('buildForUrl is stable and prefixed', () {
    final url = Uri.parse('https://example.com');
    final key1 = CacheKeyBuilder.buildForUrl(url);
    final key2 = CacheKeyBuilder.buildForUrl(url);
    expect(key1, key2);
    expect(key1.startsWith('metalink:'), isTrue);
  });

  test('buildForString uses prefix', () {
    final key = CacheKeyBuilder.buildForString('value', prefix: 'x:');
    expect(key.startsWith('x:'), isTrue);
  });
}
