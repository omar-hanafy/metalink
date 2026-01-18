import 'package:metalink/src/fetch/redirect_resolver.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../support/fake_fetcher.dart';

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
