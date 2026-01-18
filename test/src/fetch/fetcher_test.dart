import 'package:metalink/src/fetch/fetcher.dart';
import 'package:test/test.dart';

void main() {
  test('FetchResponse isOk', () {
    final ok = FetchResponse(
      url: Uri.parse('https://example.com'),
      statusCode: 200,
      headers: const {},
      bodyBytes: const [],
      truncated: false,
      duration: Duration.zero,
    );
    final bad = FetchResponse(
      url: Uri.parse('https://example.com'),
      statusCode: 500,
      headers: const {},
      bodyBytes: const [],
      truncated: false,
      duration: Duration.zero,
    );
    final err = FetchResponse(
      url: Uri.parse('https://example.com'),
      statusCode: 200,
      headers: const {},
      bodyBytes: const [],
      truncated: false,
      duration: Duration.zero,
      error: StateError('x'),
    );
    expect(ok.isOk, isTrue);
    expect(bad.isOk, isFalse);
    expect(err.isOk, isFalse);
  });
}
