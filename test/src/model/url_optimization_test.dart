import 'package:metalink/src/model/url_optimization.dart';
import 'package:test/test.dart';

void main() {
  test('RedirectHop toJson and fromJson', () {
    final hop = RedirectHop(
      from: Uri.parse('https://example.com/a'),
      to: Uri.parse('https://example.com/b'),
      statusCode: 301,
      location: 'https://example.com/b',
    );
    final decoded = RedirectHop.fromJson(hop.toJson());
    expect(decoded.from.toString(), 'https://example.com/a');
    expect(decoded.to.toString(), 'https://example.com/b');
    expect(decoded.statusCode, 301);
  });

  test('UrlOptimizationResult isOk', () {
    final ok = UrlOptimizationResult(
      originalUrl: Uri.parse('https://example.com'),
      finalUrl: Uri.parse('https://example.com'),
      redirects: const [],
      statusCode: 200,
      duration: Duration.zero,
    );
    expect(ok.isOk, isTrue);

    final bad = UrlOptimizationResult(
      originalUrl: Uri.parse('https://example.com'),
      finalUrl: Uri.parse('https://example.com'),
      redirects: const [],
      statusCode: 500,
      duration: Duration.zero,
    );
    expect(bad.isOk, isFalse);
  });
}
