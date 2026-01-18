import 'dart:convert';

import 'package:metalink/src/fetch/html_snippet_fetcher.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../support/fake_fetcher.dart';

void main() {
  test('returns early on non-html content-type from HEAD', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerHeadResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
      ),
    );

    final snippet = HtmlSnippetFetcher(fetcher: fetcher);
    final result = await snippet.fetch(url, options: const FetchOptions());
    expect(result.statusCode, 200);
    expect(result.bodyBytes, isEmpty);
    expect(result.error, isNull);
  });

  test('HEAD redirect loop returns error', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerHeadResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 301,
        headers: const {'location': 'https://example.com/a'},
      ),
    );

    final snippet = HtmlSnippetFetcher(fetcher: fetcher);
    final result = await snippet.fetch(url, options: const FetchOptions());
    expect(result.error, isNotNull);
  });

  test('falls back to GET when HEAD blocked', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerHeadResponse(
      url,
      FakeFetcher.buildResponse(url: url, statusCode: 405),
    );
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html'},
        bodyText: '<html></html>',
      ),
    );

    final snippet = HtmlSnippetFetcher(fetcher: fetcher);
    final result = await snippet.fetch(url, options: const FetchOptions());
    expect(result.statusCode, 200);
    expect(result.bodyText, isNotNull);
  });

  test('GET redirect chain works when stopAfterHead is false', () async {
    final fetcher = FakeFetcher();
    final url1 = Uri.parse('https://example.com/a');
    final url2 = Uri.parse('https://example.com/b');
    fetcher.registerGetResponse(
      url1,
      FakeFetcher.buildResponse(
        url: url1,
        statusCode: 302,
        headers: const {'location': 'https://example.com/b'},
      ),
    );
    fetcher.registerGetResponse(
      url2,
      FakeFetcher.buildResponse(
        url: url2,
        statusCode: 200,
        headers: const {'content-type': 'text/html'},
        bodyText: '<html></html>',
      ),
    );

    final snippet = HtmlSnippetFetcher(fetcher: fetcher);
    final result = await snippet.fetch(
      url1,
      options: const FetchOptions(stopAfterHead: false),
    );
    expect(result.finalUrl, url2);
    expect(result.redirects.length, 1);
  });

  test('detects charset from header', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    final bytes = latin1.encode('caf\u00e9');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html; charset=latin1'},
        bodyBytes: bytes,
      ),
    );

    final snippet = HtmlSnippetFetcher(fetcher: fetcher);
    final result = await snippet.fetch(
      url,
      options: const FetchOptions(stopAfterHead: false),
    );
    expect(result.detectedCharset, 'latin1');
    expect(result.charsetSource, CharsetSource.header);
  });

  test('detects charset from meta', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    final html = '<meta charset="utf-8"><div>ok</div>';
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html'},
        bodyText: html,
      ),
    );

    final snippet = HtmlSnippetFetcher(fetcher: fetcher);
    final result = await snippet.fetch(
      url,
      options: const FetchOptions(stopAfterHead: false),
    );
    expect(result.detectedCharset, 'utf-8');
    expect(result.charsetSource, CharsetSource.meta);
  });

  test('detects charset from BOM', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    final bytes = <int>[0xEF, 0xBB, 0xBF, 0x61, 0x62, 0x63];
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html'},
        bodyBytes: bytes,
      ),
    );

    final snippet = HtmlSnippetFetcher(fetcher: fetcher);
    final result = await snippet.fetch(
      url,
      options: const FetchOptions(stopAfterHead: false),
    );
    expect(result.charsetSource, CharsetSource.bom);
  });

  test('marks truncated body when maxBytes exceeded', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    final body = '0123456789abcdef';
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html'},
        bodyText: body,
      ),
    );

    final snippet = HtmlSnippetFetcher(fetcher: fetcher);
    final result = await snippet.fetch(
      url,
      options: const FetchOptions(stopAfterHead: false, maxBytes: 5),
    );
    expect(result.truncated, isTrue);
    expect(result.bodyBytes.length, 5);
  });
}
