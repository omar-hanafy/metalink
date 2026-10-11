// Runs on every platform. Browser timers fire at once when a delay exceeds
// 2^31-1 ms (about 24.8 days), so run this file with `-p chrome` as well to
// cover the web behavior these tests guard.
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:metalink/metalink.dart';
import 'package:metalink/src/network/deadline_timer.dart';
import 'package:test/test.dart';

import '../../support/fake_fetcher.dart';

/// Longer than any single browser timer can wait.
const _thirtyDays = Duration(days: 30);

/// About 100,000 years, still representable on every platform.
const _hugeBudget = Duration(days: 365 * 100000);

const _transportDelay = Duration(milliseconds: 100);

void main() {
  group('startDeadlineTimer', () {
    test('fires once, after the full delay, across several segments', () async {
      final elapsed = Stopwatch()..start();
      final fired = Completer<Duration>();
      var calls = 0;
      startDeadlineTimer(const Duration(milliseconds: 60), () {
        calls++;
        if (!fired.isCompleted) fired.complete(elapsed.elapsed);
      }, maxSegment: const Duration(milliseconds: 15));

      final firedAfter = await fired.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        firedAfter,
        greaterThanOrEqualTo(const Duration(milliseconds: 55)),
      );
      expect(calls, 1);
    });

    test('cancel stops a timer that is between segments', () async {
      var fired = false;
      final timer = startDeadlineTimer(
        const Duration(milliseconds: 300),
        () => fired = true,
        maxSegment: const Duration(milliseconds: 10),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(timer.isActive, isTrue);

      timer.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(timer.isActive, isFalse);
      expect(fired, isFalse);
    });

    test('a zero or negative delay fires', () async {
      final zero = Completer<void>();
      final negative = Completer<void>();
      startDeadlineTimer(Duration.zero, zero.complete);
      startDeadlineTimer(const Duration(seconds: -1), negative.complete);

      await Future.wait([zero.future, negative.future]);
    });

    for (final delay in [_thirtyDays, _hugeBudget]) {
      test('a ${delay.inDays}-day delay does not fire early', () async {
        var fired = false;
        final timer = startDeadlineTimer(delay, () => fired = true);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(fired, isFalse);
        expect(timer.isActive, isTrue);
        timer.cancel();
      });
    }
  });

  group('budgets longer than one platform timer', () {
    for (final budget in [_thirtyDays, _hugeBudget]) {
      test('RequestEngine keeps a ${budget.inDays}-day total budget', () async {
        final url = Uri.parse('https://example.test/');
        final fetcher = FakeFetcher()
          ..registerGet(url, (_) async {
            await Future<void>.delayed(_transportDelay);
            return FakeFetcher.buildResponse(url: url);
          });

        final result = await RequestEngine(fetcher: fetcher)
            .execute(url, options: FetchOptions(totalTimeout: budget));

        expect(result.failure, isNull);
        expect(result.response?.statusCode, 200);
      });

      test(
        'HttpFetcher keeps a ${budget.inDays}-day attempt timeout',
        () async {
          final client = MockClient((request) async {
            await Future<void>.delayed(_transportDelay);
            return http.Response('ok', 200);
          });
          final fetcher = HttpFetcher(client: client);
          addTearDown(fetcher.close);

          final response = await fetcher.get(
            Uri.parse('https://example.test/'),
            options: FetchOptions(timeout: budget, totalTimeout: budget),
          );

          expect(response.error, isNull);
          expect(response.statusCode, 200);
        },
      );

      test('MetaLinkClient.extract keeps a ${budget.inDays}-day total budget '
          'and attempt timeout', () async {
        final url = Uri.parse('https://example.test/');
        final fetcher = FakeFetcher()
          ..registerGet(url, (_) async {
            await Future<void>.delayed(_transportDelay);
            return FakeFetcher.buildResponse(
              url: url,
              headers: const {'content-type': 'text/html'},
              bodyText: '<html><head><title>Long</title></head></html>',
            );
          });
        final client = MetaLinkClient(fetcher: fetcher);
        addTearDown(client.dispose);

        final result = await client.extract(
          url.toString(),
          fetchOptions: FetchOptions(timeout: budget, totalTimeout: budget),
        );

        expect(result.metadata.title, 'Long');
      });
    }
  });
}
