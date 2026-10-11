@TestOn('vm')
library;

import 'dart:io';

import 'package:metalink/metalink.dart';
import 'package:test/test.dart';

import '../../support/fake_fetcher.dart';

/// The largest [Duration], a common "no limit" sentinel.
const _unlimited = Duration(microseconds: 0x7FFFFFFFFFFFFFFF);

/// The latest instant a [DateTime] can represent.
final _latestInstant = DateTime.fromMillisecondsSinceEpoch(
  8640000000000000,
  isUtc: true,
);

void main() {
  group('total timeout beyond the DateTime range', () {
    test('RequestContext saturates the deadline at the latest instant', () {
      final context = RequestContext(totalTimeout: _unlimited);

      expect(context.deadline, _latestInstant);
      expect(context.isExpired, isFalse);
      expect(context.remaining, greaterThan(const Duration(days: 365 * 1000)));
    });

    test('an explicit earlier deadline still wins over a huge timeout', () {
      final deadline = DateTime.now().toUtc().add(const Duration(hours: 1));
      final context = RequestContext(
        totalTimeout: _unlimited,
        deadline: deadline,
      );

      expect(context.deadline, deadline);
    });

    test('RequestContext.forOperation saturates the deadline', () {
      final context = RequestContext.forOperation(totalTimeout: _unlimited);

      expect(context.deadline, _latestInstant);
      expect(context.isExpired, isFalse);
    });

    test('RequestContext.forOperation keeps an earlier parent deadline', () {
      final parent = RequestContext(totalTimeout: const Duration(minutes: 1));
      final context = RequestContext.forOperation(
        totalTimeout: _unlimited,
        parent: parent,
      );

      expect(context.deadline, parent.deadline);
    });

    test('RequestEngine.execute completes against a fake target', () async {
      final url = Uri.parse('https://example.test/');
      final fetcher = FakeFetcher()
        ..registerGetResponse(url, FakeFetcher.buildResponse(url: url));

      final result = await RequestEngine(fetcher: fetcher)
          .execute(url, options: const FetchOptions(totalTimeout: _unlimited));

      expect(result.failure, isNull);
      expect(result.isSuccess, isTrue);
      expect(result.response?.statusCode, 200);
    });

    test('RequestEngine.execute completes against localhost', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/start') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, '/end');
        } else {
          request.response.write('ok');
        }
        await request.response.close();
      });
      final fetcher = HttpFetcher();
      addTearDown(fetcher.close);

      final result = await RequestEngine(fetcher: fetcher).execute(
        Uri.parse('http://127.0.0.1:${server.port}/start'),
        options: const FetchOptions(totalTimeout: _unlimited),
        strategy: RequestMethodStrategy.headThenGet,
      );

      expect(result.failure, isNull);
      expect(result.response?.statusCode, 200);
      expect(result.response?.bodyBytes, 'ok'.codeUnits);
      expect(result.redirects, hasLength(1));
    });

    test('MetaLinkClient.extract completes normally', () async {
      final url = Uri.parse('https://example.test/');
      final fetcher = FakeFetcher()
        ..registerGetResponse(
          url,
          FakeFetcher.buildResponse(
            url: url,
            headers: const {'content-type': 'text/html'},
            bodyText: '<html><head><title>Unlimited</title></head></html>',
          ),
        );
      final client = MetaLinkClient(fetcher: fetcher);
      addTearDown(client.dispose);

      final result = await client.extract(
        url.toString(),
        fetchOptions: const FetchOptions(totalTimeout: _unlimited),
      );

      expect(result.metadata.title, 'Unlimited');
    });
  });
}
