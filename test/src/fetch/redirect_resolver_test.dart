import 'package:http/http.dart' as http;
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/fetch/http_fetcher.dart';
import 'package:metalink/src/fetch/redirect_resolver.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../support/fake_fetcher.dart';
import '../../support/fake_http_client.dart';

void main() {
  test('resolve returns early when redirects disabled', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerHeadResponse(
      url,
      FakeFetcher.buildResponse(url: url, statusCode: 200),
    );

    final resolver = RedirectResolver(fetcher: fetcher);
    final result = await resolver.resolve(
      url,
      options: const FetchOptions(followRedirects: false),
    );
    expect(result.finalUrl, url);
    expect(result.redirects, isEmpty);
    expect(
      fetcher.requests.single.headers?['user-agent'],
      'MetaLink (+https://github.com/omar-hanafy/metalink)',
    );
  });

  test('resolve follows redirects with head', () async {
    final fetcher = FakeFetcher();
    final url1 = Uri.parse('https://example.com/a');
    final url2 = Uri.parse('https://example.com/b');

    fetcher.registerHeadResponse(
      url1,
      FakeFetcher.buildResponse(
        url: url1,
        statusCode: 301,
        headers: const {'location': 'https://example.com/b'},
      ),
    );
    fetcher.registerHeadResponse(
      url2,
      FakeFetcher.buildResponse(url: url2, statusCode: 200),
    );

    final resolver = RedirectResolver(fetcher: fetcher);
    final result = await resolver.resolve(
      url1,
      options: const FetchOptions(maxRedirects: 2),
    );
    expect(result.finalUrl, url2);
    expect(result.redirects.length, 1);
  });

  test('resolve falls back to get when head blocked', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerHeadResponse(
      url,
      FakeFetcher.buildResponse(url: url, statusCode: 405),
    );
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(url: url, statusCode: 200),
    );

    final resolver = RedirectResolver(fetcher: fetcher);
    final result = await resolver.resolve(
      url,
      options: const FetchOptions(maxRedirects: 1),
    );
    expect(result.statusCode, 200);
  });

  test('resolve falls back to get when one head attempt times out', () async {
    final client = RecordingHttpClient(
      handler: (request) async {
        if (request.method == 'HEAD') {
          // Never answer HEAD; only HttpFetcher's per-attempt abort ends it.
          await (request as http.AbortableRequest).abortTrigger;
          throw http.RequestAbortedException(request.url);
        }
        return stringResponse('', 200);
      },
    );
    final fetcher = HttpFetcher(
      client: client,
      capabilities: const FetcherCapabilities(
        supportsAbort: true,
        redirectHandling: RedirectHandlingCapability.inspectable,
      ),
    );
    addTearDown(fetcher.close);

    final result = await RedirectResolver(fetcher: fetcher).resolve(
      Uri.parse('https://slow-head.test/a'),
      options: const FetchOptions(
        timeout: Duration(milliseconds: 50),
        totalTimeout: Duration(seconds: 10),
      ),
    );

    expect(result.error, isNull);
    expect(result.statusCode, 200);
    expect(client.requests.map((request) => request.method), <String>[
      'HEAD',
      'GET',
    ]);
  });

  test('resolve stops on invalid location', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerHeadResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 301,
        headers: const {'location': '::bad::'},
      ),
    );

    final resolver = RedirectResolver(fetcher: fetcher);
    final result = await resolver.resolve(
      url,
      options: const FetchOptions(maxRedirects: 2),
    );
    expect(result.finalUrl, url);
    expect(result.redirects, isEmpty);
  });

  test('resolve errors when too many redirects', () async {
    final fetcher = FakeFetcher();
    final url1 = Uri.parse('https://example.com/a');
    final url2 = Uri.parse('https://example.com/b');
    fetcher.registerHeadResponse(
      url1,
      FakeFetcher.buildResponse(
        url: url1,
        statusCode: 301,
        headers: const {'location': 'https://example.com/b'},
      ),
    );
    fetcher.registerHeadResponse(
      url2,
      FakeFetcher.buildResponse(
        url: url2,
        statusCode: 301,
        headers: const {'location': 'https://example.com/a'},
      ),
    );

    final resolver = RedirectResolver(fetcher: fetcher);
    final result = await resolver.resolve(
      url1,
      options: const FetchOptions(maxRedirects: 1),
    );
    expect(result.error, isNotNull);
  });
}
