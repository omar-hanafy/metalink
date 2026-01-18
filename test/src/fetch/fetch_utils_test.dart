import 'package:metalink/src/fetch/fetch_utils.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../support/fake_fetcher.dart';

void main() {
  test('getWithRedirects returns response when redirects disabled', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(url: url, statusCode: 200),
    );

    final resp = await FetchUtils.getWithRedirects(
      fetcher,
      url,
      options: const FetchOptions(followRedirects: false),
    );
    expect(resp.statusCode, 200);
  });

  test('getWithRedirects follows redirects', () async {
    final fetcher = FakeFetcher();
    final url1 = Uri.parse('https://example.com/a');
    final url2 = Uri.parse('https://example.com/b');
    fetcher.registerGetResponse(
      url1,
      FakeFetcher.buildResponse(
        url: url1,
        statusCode: 301,
        headers: const {'location': 'https://example.com/b'},
      ),
    );
    fetcher.registerGetResponse(
      url2,
      FakeFetcher.buildResponse(url: url2, statusCode: 200),
    );

    final resp = await FetchUtils.getWithRedirects(
      fetcher,
      url1,
      options: const FetchOptions(maxRedirects: 2),
    );
    expect(resp.statusCode, 200);
    expect(fetcher.requests.length, 2);
  });

  test('getWithRedirects errors on too many redirects', () async {
    final fetcher = FakeFetcher();
    final url1 = Uri.parse('https://example.com/a');
    final url2 = Uri.parse('https://example.com/b');
    fetcher.registerGetResponse(
      url1,
      FakeFetcher.buildResponse(
        url: url1,
        statusCode: 301,
        headers: const {'location': 'https://example.com/b'},
      ),
    );
    fetcher.registerGetResponse(
      url2,
      FakeFetcher.buildResponse(
        url: url2,
        statusCode: 301,
        headers: const {'location': 'https://example.com/a'},
      ),
    );

    final resp = await FetchUtils.getWithRedirects(
      fetcher,
      url1,
      options: const FetchOptions(maxRedirects: 1),
    );
    expect(resp.error, isNotNull);
  });

  test('getWithRedirects errors on invalid location', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 301,
        headers: const {'location': '::bad::'},
      ),
    );

    final resp = await FetchUtils.getWithRedirects(
      fetcher,
      url,
      options: const FetchOptions(maxRedirects: 2),
    );
    expect(resp.error, isNotNull);
  });

  test('getWithRedirects errors on redirect loop to self', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 301,
        headers: const {'location': 'https://example.com/a'},
      ),
    );

    final resp = await FetchUtils.getWithRedirects(
      fetcher,
      url,
      options: const FetchOptions(maxRedirects: 2),
    );
    expect(resp.error, isNotNull);
  });

  test('getWithRedirects applies proxy before fetch', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    final proxied = Uri.parse('https://proxy.test/https://example.com/a');
    fetcher.registerGetResponse(
      proxied,
      FakeFetcher.buildResponse(url: proxied, statusCode: 200),
    );

    final resp = await FetchUtils.getWithRedirects(
      fetcher,
      url,
      options: const FetchOptions(proxyUrl: 'https://proxy.test/'),
    );
    expect(resp.statusCode, 200);
    expect(fetcher.requests.first.url.toString(), proxied.toString());
  });
}
