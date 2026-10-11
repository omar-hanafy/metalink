import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/fetch/http_fetcher.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../support/fake_http_client.dart';

void main() {
  test('HttpFetcher sets user-agent header', () async {
    final client = RecordingHttpClient(
      handler: (request) async {
        return stringResponse('ok', 200);
      },
    );
    final fetcher = HttpFetcher(client: client);

    await fetcher.get(
      Uri.parse('https://example.com'),
      options: const FetchOptions(userAgent: 'agent'),
    );

    final req = client.requests.first;
    expect(req.headers['user-agent'], 'agent');
  });

  test('HttpFetcher merges per-call headers', () async {
    final client = RecordingHttpClient(
      handler: (request) async {
        return stringResponse('ok', 200);
      },
    );
    final fetcher = HttpFetcher(client: client);

    await fetcher.get(
      Uri.parse('https://example.com'),
      options: const FetchOptions(headers: {'x-test': 'a'}),
      headers: const {'x-test': 'b'},
    );

    final req = client.requests.first;
    expect(req.headers['x-test'], 'b');
  });

  test('HttpFetcher returns error on timeout', () async {
    final client = RecordingHttpClient(
      handler: (request) async {
        return Future<http.StreamedResponse>.error(TimeoutException('timeout'));
      },
    );
    final fetcher = HttpFetcher(client: client);
    final resp = await fetcher.get(
      Uri.parse('https://example.com'),
      options: const FetchOptions(timeout: Duration(milliseconds: 1)),
    );
    expect(resp.error, isA<TimeoutException>());
  });

  test('HttpFetcher does not close injected client', () {
    final client = RecordingHttpClient(
      handler: (request) async => stringResponse('ok', 200),
    );
    final fetcher = HttpFetcher(client: client);
    fetcher.close();
    expect(client.closed, isFalse);
  });

  test('HttpFetcher does not overstate injected client capabilities', () {
    final client = RecordingHttpClient(
      handler: (request) async => stringResponse('ok', 200),
    );
    final fetcher = HttpFetcher(client: client);

    expect(fetcher.capabilities.supportsAbort, isFalse);
    expect(
      fetcher.capabilities.redirectHandling,
      RedirectHandlingCapability.unknown,
    );
  });

  test('HttpFetcher closes a client created by its factory', () {
    final client = RecordingHttpClient(
      handler: (request) async => stringResponse('ok', 200),
    );
    final fetcher = HttpFetcher(clientFactory: () => client);

    expect(fetcher.capabilities.supportsAbort, isFalse);
    expect(
      fetcher.capabilities.redirectHandling,
      RedirectHandlingCapability.unknown,
    );

    fetcher.close();

    expect(client.closed, isTrue);
  });

  test('HttpFetcher accepts explicit capabilities for a custom factory', () {
    final client = RecordingHttpClient(
      handler: (request) async => stringResponse('ok', 200),
    );
    const capabilities = FetcherCapabilities(
      supportsAbort: true,
      redirectHandling: RedirectHandlingCapability.inspectable,
    );
    final fetcher = HttpFetcher(
      clientFactory: () => client,
      capabilities: capabilities,
    );

    expect(fetcher.capabilities, same(capabilities));

    fetcher.close();
  });

  test('uninspectable transport can follow and report its final URL', () async {
    final start = Uri.parse('https://start.test/');
    final finalUrl = Uri.parse('https://final.test/page');
    final client = RecordingHttpClient(
      handler: (request) async {
        expect(request.followRedirects, isTrue);
        expect(request.maxRedirects, 3);
        return _ResponseWithUrl(200, url: finalUrl);
      },
    );
    final fetcher = HttpFetcher(
      client: client,
      capabilities: const FetcherCapabilities(
        supportsAbort: true,
        redirectHandling: RedirectHandlingCapability.unavailable,
      ),
    );

    final response = await fetcher.get(
      start,
      options: const FetchOptions(maxRedirects: 3),
    );

    expect(response.error, isNull);
    expect(response.url, finalUrl);
  });

  // HttpFetcher converts every exception from send() into
  // FetchResponse.error, so these tests assert on the recorded request after
  // get() returns instead of inside the client handler.
  for (final (label, options) in <(String, FetchOptions)>[
    ('disabled', const FetchOptions(followRedirects: false)),
    ('the redirect budget is zero', const FetchOptions(maxRedirects: 0)),
  ]) {
    test('uninspectable transport does not follow when $label', () async {
      final start = Uri.parse('https://start.test/');
      final client = RecordingHttpClient(
        handler: (request) async => _ResponseWithUrl(302, url: start),
      );
      final fetcher = HttpFetcher(
        client: client,
        capabilities: const FetcherCapabilities(
          supportsAbort: true,
          redirectHandling: RedirectHandlingCapability.unavailable,
        ),
      );

      final response = await fetcher.get(start, options: options);

      expect(response.error, isNull);
      expect(response.statusCode, 302);
      final request = client.requests.single;
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
    });
  }

  // The largest int cannot be incremented to detect truncation, so it must
  // behave as "no limit" instead of overflowing.
  const maxInt = 0x7fffffffffffffff;
  for (final (label, options, perCall) in <(String, FetchOptions, int?)>[
    ('FetchOptions.maxBytes', const FetchOptions(maxBytes: maxInt), null),
    ('a per-call maxBytes', const FetchOptions(), maxInt),
  ]) {
    test('$label at the integer maximum reads the whole body', () async {
      final body = List<int>.generate(70000, (index) => index % 251);
      final client = RecordingHttpClient(
        handler: (request) async => http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[
            body.sublist(0, 30000),
            body.sublist(30000),
          ]),
          200,
        ),
      );
      final fetcher = HttpFetcher(client: client);

      final response = await fetcher.get(
        Uri.parse('https://example.com/large'),
        options: options,
        maxBytes: perCall,
      );

      expect(response.error, isNull);
      expect(response.truncated, isFalse);
      expect(response.bodyBytes, body);
    });
  }

  test('HttpFetcher actively aborts an in-flight request on timeout', () async {
    final abortObserved = Completer<void>();
    final client = RecordingHttpClient(
      handler: (request) async {
        final abortable = request as http.AbortableRequest;
        await abortable.abortTrigger;
        abortObserved.complete();
        throw http.RequestAbortedException(request.url);
      },
    );
    final fetcher = HttpFetcher(client: client);

    final response = await fetcher.get(
      Uri.parse('https://slow.test/'),
      options: const FetchOptions(timeout: Duration(milliseconds: 10)),
    );

    expect(response.error, isA<TimeoutException>());
    await expectLater(abortObserved.future, completes);
  });

  test('HttpFetcher actively aborts on external cancellation', () async {
    final cancellation = Completer<void>();
    final abortObserved = Completer<void>();
    final client = RecordingHttpClient(
      handler: (request) async {
        final abortable = request as http.AbortableRequest;
        await abortable.abortTrigger;
        abortObserved.complete();
        throw http.RequestAbortedException(request.url);
      },
    );
    final fetcher = HttpFetcher(client: client);

    final pending = fetcher.get(
      Uri.parse('https://slow.test/'),
      options: const FetchOptions(timeout: Duration(seconds: 1)),
      abortTrigger: cancellation.future,
    );
    cancellation.complete();
    final response = await pending;

    expect(response.error, isA<FetchCancellationException>());
    await expectLater(abortObserved.future, completes);
  });
}

class _ResponseWithUrl extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _ResponseWithUrl(int statusCode, {required this.url})
    : super(const Stream<List<int>>.empty(), statusCode);

  @override
  final Uri url;
}
