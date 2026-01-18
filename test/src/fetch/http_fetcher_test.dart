import 'dart:async';

import 'package:http/http.dart' as http;
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
        return Future<http.StreamedResponse>.error(
          TimeoutException('timeout'),
        );
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
}
