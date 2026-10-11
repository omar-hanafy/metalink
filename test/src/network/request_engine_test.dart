import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/fetch/http_fetcher.dart';
import 'package:metalink/src/network/request_context.dart';
import 'package:metalink/src/network/request_engine.dart';
import 'package:metalink/src/network/request_policy.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../support/fake_fetcher.dart';
import '../../support/fake_http_client.dart';

void main() {
  group('redirect invariants', () {
    test('zero redirect budget rejects the first redirect', () async {
      final first = Uri.parse('https://first.test/a');
      final second = Uri.parse('https://first.test/b');
      final fetcher = FakeFetcher()
        ..registerGetResponse(first, _redirect(first, second));

      final result = await RequestEngine(fetcher: fetcher)
          .execute(first, options: const FetchOptions(maxRedirects: 0));

      expect(result.failure?.code, RequestFailureCode.redirectLimit);
      expect(result.finalUrl, first);
      expect(result.redirects, isEmpty);
      expect(fetcher.requests, hasLength(1));
    });

    test(
      'maxRedirects allows exactly that many hops and terminal request',
      () async {
        final first = Uri.parse('https://first.test/a');
        final terminal = Uri.parse('https://first.test/b');
        final fetcher = FakeFetcher()
          ..registerGetResponse(
            first,
            FakeFetcher.buildResponse(
              url: first,
              statusCode: 302,
              headers: {'location': terminal.toString()},
            ),
          )
          ..registerGetResponse(
            terminal,
            FakeFetcher.buildResponse(url: terminal, statusCode: 200),
          );

        final result = await RequestEngine(fetcher: fetcher)
            .execute(first, options: const FetchOptions(maxRedirects: 1));

        expect(result.failure, isNull);
        expect(result.finalUrl, terminal.replace(path: '/b'));
        expect(result.redirects, hasLength(1));
        expect(fetcher.requests, hasLength(2));
      },
    );

    test('fails only when another redirect exceeds the exact limit', () async {
      final first = Uri.parse('https://first.test/a');
      final second = Uri.parse('https://first.test/b');
      final third = Uri.parse('https://first.test/c');
      final fetcher = FakeFetcher()
        ..registerGetResponse(
          first,
          FakeFetcher.buildResponse(
            url: first,
            statusCode: 302,
            headers: {'location': second.toString()},
          ),
        )
        ..registerGetResponse(
          second,
          FakeFetcher.buildResponse(
            url: second,
            statusCode: 302,
            headers: {'location': third.toString()},
          ),
        );

      final result = await RequestEngine(fetcher: fetcher)
          .execute(first, options: const FetchOptions(maxRedirects: 1));

      expect(result.failure?.code, RequestFailureCode.redirectLimit);
      expect(result.finalUrl, second);
      expect(result.redirects, hasLength(1));
      expect(fetcher.requests, hasLength(2));
    });

    test('detects a loop across multiple distinct hops', () async {
      final first = Uri.parse('https://loop.test/a');
      final second = Uri.parse('https://loop.test/b');
      final third = Uri.parse('https://loop.test/c');
      final fetcher = FakeFetcher()
        ..registerGetResponse(first, _redirect(first, second))
        ..registerGetResponse(second, _redirect(second, third))
        ..registerGetResponse(third, _redirect(third, second));

      final result = await RequestEngine(fetcher: fetcher)
          .execute(first, options: const FetchOptions(maxRedirects: 10));

      expect(result.failure?.code, RequestFailureCode.redirectLoop);
      expect(fetcher.requests, hasLength(3));
    });
  });

  group('policy boundary', () {
    group('fetcher that follows redirects itself', () {
      late HttpServer public;
      late HttpServer internal;

      setUp(() async {
        internal = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        internal.listen((request) {
          request.response.write('internal secret');
          request.response.close();
        });
        public = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        public.listen((request) {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(
              HttpHeaders.locationHeader,
              'http://127.0.0.1:${internal.port}/secret',
            );
          request.response.close();
        });
      });

      tearDown(() async {
        await public.close(force: true);
        await internal.close(force: true);
      });

      RequestPolicy policy({required bool requireInspectable}) => RequestPolicy(
        requireInspectableRedirects: requireInspectable,
        targetValidator: (target) => target.uri.port == internal.port
            ? const RequestPolicyDecision.reject('internal port')
            : const RequestPolicyDecision.allow(),
      );

      test(
        'fails closed when the policy requires inspectable redirects',
        () async {
          final fetcher = _AutoFollowingFetcher();
          addTearDown(fetcher.close);

          final result = await RequestEngine(fetcher: fetcher).execute(
            Uri.parse('http://127.0.0.1:${public.port}/'),
            options: FetchOptions(
              requestPolicy: policy(requireInspectable: true),
            ),
          );

          expect(
            result.failure?.code,
            RequestFailureCode.unsupportedCapability,
          );
          // The internal body must not reach the caller.
          expect(result.response, isNull);
          expect(result.toFetchResponse().bodyBytes, isEmpty);
        },
      );

      test('is still accepted when the policy does not require it', () async {
        final fetcher = _AutoFollowingFetcher();
        addTearDown(fetcher.close);

        final result = await RequestEngine(fetcher: fetcher).execute(
          Uri.parse('http://127.0.0.1:${public.port}/'),
          options: FetchOptions(
            requestPolicy: policy(requireInspectable: false),
          ),
        );

        expect(result.failure, isNull);
      });
    });

    test(
      'fails closed when a fetcher declared inspectable reports another URL',
      () async {
        final requested = Uri.parse('https://public.test/');
        final fetcher =
            _CapabilityFetcher(
              capabilities: const FetcherCapabilities(
                supportsAbort: false,
                redirectHandling: RedirectHandlingCapability.inspectable,
              ),
            )..registerGetResponse(
              requested,
              FakeFetcher.buildResponse(
                url: Uri.parse('https://internal.test/secret'),
                statusCode: 200,
              ),
            );

        final result = await RequestEngine(fetcher: fetcher).execute(
          requested,
          options: const FetchOptions(
            requestPolicy: RequestPolicy(requireInspectableRedirects: true),
          ),
        );

        expect(result.failure?.code, RequestFailureCode.unsupportedCapability);
        expect(result.response, isNull);
      },
    );

    test('accepts a reported URL that only omits the userinfo', () async {
      final requested = Uri.parse('https://alice:s3cret@public.test/page');
      final fetcher = FakeFetcher()
        ..registerGetResponse(
          requested,
          FakeFetcher.buildResponse(
            url: Uri.parse('https://public.test/page'),
            statusCode: 200,
          ),
        );

      final result = await RequestEngine(fetcher: fetcher).execute(
        requested,
        options: const FetchOptions(
          requestPolicy: RequestPolicy(requireInspectableRedirects: true),
        ),
      );

      expect(result.failure, isNull);
    });

    test('accepts a reported URL that differs only by normalization', () async {
      final requested = Uri.parse('https://public.test/path?q=1');
      final fetcher = FakeFetcher()
        ..registerGetResponse(
          requested,
          FakeFetcher.buildResponse(
            url: Uri.parse('HTTPS://Public.test:443/path?q=1#fragment'),
            statusCode: 200,
          ),
        );

      final result = await RequestEngine(fetcher: fetcher).execute(
        requested,
        options: const FetchOptions(
          requestPolicy: RequestPolicy(requireInspectableRedirects: true),
        ),
      );

      expect(result.failure, isNull);
    });

    test('rejects an async initial target before transport', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://blocked.test/');
      final policy = RequestPolicy(
        targetValidator: (target) async {
          await Future<void>.delayed(Duration.zero);
          return const RequestPolicyDecision.reject('blocked');
        },
      );

      final result = await RequestEngine(fetcher: fetcher)
          .execute(url, options: FetchOptions(requestPolicy: policy));

      expect(result.failure?.code, RequestFailureCode.policyRejected);
      expect(fetcher.requests, isEmpty);
    });

    test('validator exceptions fail closed without escaping', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://policy.test/');
      final policy = RequestPolicy(
        targetValidator: (_) => throw StateError('validator failed'),
      );

      final result = await RequestEngine(fetcher: fetcher)
          .execute(url, options: FetchOptions(requestPolicy: policy));

      expect(result.failure?.code, RequestFailureCode.policyRejected);
      expect(result.failure?.cause, isA<StateError>());
      expect(fetcher.requests, isEmpty);
    });

    test('complete deadline also bounds async policy evaluation', () async {
      final fetcher = FakeFetcher();
      final validator = Completer<RequestPolicyDecision>();
      final policy = RequestPolicy(targetValidator: (_) => validator.future);

      final result = await RequestEngine(fetcher: fetcher).execute(
        Uri.parse('https://policy.test/'),
        options: FetchOptions(
          totalTimeout: const Duration(milliseconds: 10),
          requestPolicy: policy,
        ),
      );

      expect(result.failure?.code, RequestFailureCode.timeout);
      expect(fetcher.requests, isEmpty);
    });

    test('revalidates every redirect before requesting it', () async {
      final first = Uri.parse('https://allowed.test/');
      final blocked = Uri.parse('https://blocked.test/');
      final fetcher = FakeFetcher()
        ..registerGetResponse(first, _redirect(first, blocked));
      final policy = RequestPolicy(
        targetValidator: (target) => target.uri.host == 'blocked.test'
            ? const RequestPolicyDecision.reject('blocked redirect')
            : const RequestPolicyDecision.allow(),
      );

      final result = await RequestEngine(fetcher: fetcher)
          .execute(first, options: FetchOptions(requestPolicy: policy));

      expect(result.failure?.code, RequestFailureCode.policyRejected);
      expect(result.finalUrl.host, 'blocked.test');
      expect(fetcher.requests, hasLength(1));
    });

    test('secure policy rejects uninspectable redirect transport', () async {
      final url = Uri.parse('https://example.test/');
      final fetcher = _CapabilityFetcher(
        capabilities: const FetcherCapabilities(
          supportsAbort: true,
          redirectHandling: RedirectHandlingCapability.unavailable,
          limitation: 'redirects hidden',
        ),
      );

      final result = await RequestEngine(fetcher: fetcher).execute(
        url,
        options: FetchOptions(requestPolicy: RequestPolicy.secure()),
      );

      expect(result.failure?.code, RequestFailureCode.unsupportedCapability);
      expect(
        result.capabilities.redirectHandling,
        RedirectHandlingCapability.unavailable,
      );
      expect(fetcher.requests, isEmpty);
    });

    test('secure policy rejects a redirect to a non-ASCII host', () async {
      final first = Uri.parse('https://public.test/');
      final fullwidthLoopback = Uri.parse('http://１２７.０.０.１/admin');
      final fetcher = FakeFetcher()
        ..registerGetResponse(first, _redirect(first, fullwidthLoopback));

      final result = await RequestEngine(fetcher: fetcher).execute(
        first,
        options: FetchOptions(requestPolicy: RequestPolicy.secure()),
      );

      expect(result.failure?.code, RequestFailureCode.policyRejected);
      expect(result.failure?.message, contains('xn--'));
      expect(fetcher.requests, hasLength(1));
      expect(fetcher.requests.single.url, first);
    });
  });

  test(
    'compatible uninspectable transport preserves its hidden final URL',
    () async {
      final start = Uri.parse('https://start.test/');
      final finalUrl = Uri.parse('https://final.test/page');
      final client = RecordingHttpClient(
        handler: (request) async {
          expect(request.followRedirects, isTrue);
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

      final result = await RequestEngine(fetcher: fetcher)
          .execute(start, options: const FetchOptions());

      expect(result.failure, isNull);
      expect(result.finalUrl, finalUrl);
      expect(result.response?.url, finalUrl);
      expect(result.redirects, isEmpty);
      expect(client.requests, hasLength(1));
      fetcher.close();
    },
  );

  group('credential boundary', () {
    test(
      'strips secrets cross-origin and never readds options headers',
      () async {
        final first = Uri.parse('https://origin.test/');
        final second = Uri.parse('https://other.test/');
        final fetcher = FakeFetcher()
          ..registerGetResponse(first, _redirect(first, second))
          ..registerGetResponse(
            second,
            FakeFetcher.buildResponse(url: second, statusCode: 200),
          );

        final result = await RequestEngine(fetcher: fetcher).execute(
          first,
          options: const FetchOptions(
            headers: {
              'Authorization': 'Bearer secret',
              'Cookie': 'session=secret',
              'X-Api-Key': 'key',
              'X-Trace': 'trace',
            },
          ),
        );

        expect(result.failure, isNull);
        final initial = fetcher.requests[0];
        final redirected = fetcher.requests[1];
        expect(initial.headers?['authorization'], 'Bearer secret');
        expect(redirected.headers, isNot(contains('authorization')));
        expect(redirected.headers, isNot(contains('cookie')));
        expect(redirected.headers, isNot(contains('x-api-key')));
        expect(redirected.headers?['x-trace'], 'trace');
        expect(initial.options.headers, isEmpty);
        expect(redirected.options.headers, isEmpty);
      },
    );

    test(
      'strips document credentials from an initial enrichment request',
      () async {
        final url = Uri.parse('https://provider.test/oembed');
        final fetcher = FakeFetcher()
          ..registerGetResponse(
            url,
            FakeFetcher.buildResponse(url: url, statusCode: 200),
          );

        await RequestEngine(fetcher: fetcher).execute(
          url,
          options: const FetchOptions(
            headers: {
              'Authorization': 'Bearer secret',
              'Cookie': 'session=secret',
              'X-Trace': 'trace',
            },
          ),
          purpose: RequestPurpose.oEmbed,
        );

        final request = fetcher.requests.single;
        expect(request.headers, isNot(contains('authorization')));
        expect(request.headers, isNot(contains('cookie')));
        expect(request.headers?['x-trace'], 'trace');
        expect(request.options.headers, isEmpty);
      },
    );

    test('HttpFetcher cannot readd a stripped sensitive user-agent', () async {
      final first = Uri.parse('https://origin.test/');
      final second = Uri.parse('https://other.test/');
      final client = RecordingHttpClient(
        handler: (request) async {
          if (request.url == first) {
            return stringResponse(
              '',
              302,
              headers: <String, String>{'location': second.toString()},
            );
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

      final result = await RequestEngine(fetcher: fetcher).execute(
        first,
        options: const FetchOptions(
          userAgent: 'sensitive-agent',
          requestPolicy: RequestPolicy(sensitiveHeaders: {'user-agent'}),
        ),
      );

      expect(result.failure, isNull);
      expect(client.requests, hasLength(2));
      expect(client.requests[0].headers['user-agent'], 'sensitive-agent');
      expect(client.requests[1].headers, isNot(contains('user-agent')));
      expect(client.requests, everyElement(isA<http.AbortableRequest>()));
      fetcher.close();
    });
  });

  test('invalid proxy fails closed before transport', () async {
    final fetcher = FakeFetcher();
    final result = await RequestEngine(fetcher: fetcher).execute(
      Uri.parse('https://example.test/'),
      options: const FetchOptions(proxyUrl: 'not a proxy'),
    );

    expect(result.failure?.code, RequestFailureCode.proxyConfiguration);
    expect(fetcher.requests, isEmpty);
  });

  // The deadline tests below give the operation a ten-second budget and run
  // inside _withAcceleratedTimers, so the engine's deadline timer fires after
  // about 20 ms. Setup before the first request completes in microtasks, which
  // always run before any timer, and the context's real clock still reports
  // nearly the whole budget. The first request is therefore always sent, even
  // when the isolate is descheduled under load; a tiny real budget could
  // expire before then.
  test(
    'complete deadline stops a legacy fetcher that does not honor timeout',
    () async {
      final pending = Completer<FetchResponse>();
      final fetcher = FakeFetcher(onMissing: (_) => pending.future);

      final result = await _withAcceleratedTimers(
        () => RequestEngine(fetcher: fetcher).execute(
          Uri.parse('https://slow.test/'),
          options: const FetchOptions(
            // Longer than the complete deadline, so only the deadline can end
            // the request; this fetcher ignores it anyway.
            timeout: Duration(minutes: 1),
            totalTimeout: Duration(seconds: 10),
          ),
        ),
      );

      expect(result.failure?.code, RequestFailureCode.timeout);
      expect(fetcher.requests, hasLength(1));
    },
    timeout: const Timeout(Duration(seconds: 5)),
  );

  test('configured deadline bounds a cancellation-only context', () async {
    final pending = Completer<FetchResponse>();
    final cancellation = Completer<void>();
    final fetcher = FakeFetcher(onMissing: (_) => pending.future);

    final result = await _withAcceleratedTimers(
      () => RequestEngine(fetcher: fetcher).execute(
        Uri.parse('https://slow.test/'),
        options: const FetchOptions(
          timeout: Duration(minutes: 1),
          totalTimeout: Duration(seconds: 10),
        ),
        context: RequestContext(cancellationSignal: cancellation.future),
      ),
    );

    expect(result.failure?.code, RequestFailureCode.timeout);
    expect(fetcher.requests, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('expired HEAD budget does not start a fallback GET', () async {
    final pending = Completer<FetchResponse>();
    final fetcher = FakeFetcher(onMissing: (_) => pending.future);

    final result = await _withAcceleratedTimers(
      () => RequestEngine(fetcher: fetcher).execute(
        Uri.parse('https://slow.test/'),
        options: const FetchOptions(
          timeout: Duration(minutes: 1),
          totalTimeout: Duration(seconds: 10),
        ),
        strategy: RequestMethodStrategy.headThenGet,
      ),
    );

    expect(result.failure?.code, RequestFailureCode.timeout);
    expect(fetcher.requests, hasLength(1));
    expect(fetcher.requests.single.method, 'HEAD');
  }, timeout: const Timeout(Duration(seconds: 5)));

  group('finalUrl for each failure code', () {
    final a = Uri.parse('https://a.test/');
    final b = Uri.parse('https://b.test/');
    final c = Uri.parse('https://c.test/');

    test('invalidTarget keeps the URL passed in', () async {
      final target = Uri.parse('ftp://a.test/file');
      final result = await RequestEngine(fetcher: FakeFetcher())
          .execute(target, options: const FetchOptions());

      expect(result.failure?.code, RequestFailureCode.invalidTarget);
      expect(result.finalUrl, target);
      expect(result.failure?.uri, target);
    });

    test('policyRejected on a redirect target reports that target', () async {
      final fetcher = FakeFetcher()..registerGetResponse(a, _redirect(a, b));

      final result = await RequestEngine(fetcher: fetcher).execute(
        a,
        options: FetchOptions(
          requestPolicy: RequestPolicy(
            targetValidator: (target) => target.uri.host == 'b.test'
                ? const RequestPolicyDecision.reject('blocked')
                : const RequestPolicyDecision.allow(),
          ),
        ),
      );

      expect(result.failure?.code, RequestFailureCode.policyRejected);
      expect(result.finalUrl, b);
      expect(result.failure?.uri, b);
      expect(fetcher.requests.map((request) => request.url), [a]);
    });

    test('policyRejected on a proxy target keeps the logical target', () async {
      final result = await RequestEngine(fetcher: FakeFetcher()).execute(
        a,
        options: FetchOptions(
          proxyUrl: 'https://proxy.test/?u={urlEncoded}',
          requestPolicy: RequestPolicy(
            proxyTargetValidator: (_) =>
                const RequestPolicyDecision.reject('no proxy'),
          ),
        ),
      );

      expect(result.failure?.code, RequestFailureCode.policyRejected);
      expect(result.finalUrl, a);
      expect(result.failure?.uri.host, 'proxy.test');
    });

    test('cancellation before a redirect target is requested reports that '
        'target', () async {
      final signal = Completer<void>();
      final fetcher = FakeFetcher()..registerGetResponse(a, _redirect(a, b));

      final result = await RequestEngine(fetcher: fetcher).execute(
        a,
        options: FetchOptions(
          requestPolicy: RequestPolicy(
            targetValidator: (target) {
              if (target.uri.host == 'b.test') signal.complete();
              return const RequestPolicyDecision.allow();
            },
          ),
        ),
        context: RequestContext(cancellationSignal: signal.future),
      );

      expect(result.failure?.code, RequestFailureCode.cancelled);
      expect(result.finalUrl, b);
      expect(result.failure?.uri, b);
      expect(fetcher.requests.map((request) => request.url), [a]);
    });

    test('redirectLimit keeps the URL that returned the redirect', () async {
      final fetcher = FakeFetcher()
        ..registerGetResponse(a, _redirect(a, b))
        ..registerGetResponse(b, _redirect(b, c));

      final result = await RequestEngine(fetcher: fetcher)
          .execute(a, options: const FetchOptions(maxRedirects: 1));

      expect(result.failure?.code, RequestFailureCode.redirectLimit);
      expect(result.finalUrl, b);
      expect(result.failure?.uri, b);
      expect(fetcher.requests.map((request) => request.url), [a, b]);
    });

    test('redirectLoop keeps the URL that returned the redirect and reports '
        'the repeated target', () async {
      final fetcher = FakeFetcher()
        ..registerGetResponse(a, _redirect(a, b))
        ..registerGetResponse(b, _redirect(b, a));

      final result = await RequestEngine(fetcher: fetcher)
          .execute(a, options: const FetchOptions());

      expect(result.failure?.code, RequestFailureCode.redirectLoop);
      expect(result.finalUrl, b);
      expect(result.failure?.uri, a);
    });

    test('invalidRedirect keeps the URL that returned the redirect', () async {
      final fetcher = FakeFetcher()
        ..registerGetResponse(
          a,
          FakeFetcher.buildResponse(
            url: a,
            statusCode: 302,
            headers: const {'location': 'mailto:someone@a.test'},
          ),
        );

      final result = await RequestEngine(fetcher: fetcher)
          .execute(a, options: const FetchOptions());

      expect(result.failure?.code, RequestFailureCode.invalidRedirect);
      expect(result.finalUrl, a);
      expect(result.failure?.uri, a);
    });

    test('an invalid opaque final URL keeps the requested URL', () async {
      final reported = Uri.parse('ftp://elsewhere.test/');
      final fetcher = _CapabilityFetcher(
        capabilities: const FetcherCapabilities(
          supportsAbort: false,
          redirectHandling: RedirectHandlingCapability.unavailable,
        ),
      )..registerGetResponse(a, FakeFetcher.buildResponse(url: reported));

      final result = await RequestEngine(fetcher: fetcher)
          .execute(a, options: const FetchOptions());

      expect(result.failure?.code, RequestFailureCode.invalidRedirect);
      expect(result.finalUrl, a);
      expect(result.failure?.uri, reported);
    });

    test('a transport failure keeps the requested URL', () async {
      final fetcher = FakeFetcher()
        ..registerGetResponse(a, _transportError(a, StateError('down')));

      final result = await RequestEngine(fetcher: fetcher)
          .execute(a, options: const FetchOptions());

      expect(result.failure?.code, RequestFailureCode.transport);
      expect(result.finalUrl, a);
      expect(result.failure?.uri, a);
    });
  });

  group('HEAD fallback lifetime', () {
    const headStrategies = <RequestMethodStrategy>[
      RequestMethodStrategy.headThenGet,
      RequestMethodStrategy.headWithGetFallback,
    ];

    for (final strategy in headStrategies) {
      test('${strategy.name}: per-attempt HEAD timeout falls back to GET while '
          'budget remains', () async {
        final url = Uri.parse('https://slow-head.test/');
        final fetcher = FakeFetcher()
          ..registerHeadResponse(
            url,
            _transportError(
              url,
              // The same error HttpFetcher reports when one attempt exceeds
              // FetchOptions.timeout.
              TimeoutException('Request timed out', const Duration(seconds: 1)),
            ),
          )
          ..registerGetResponse(
            url,
            FakeFetcher.buildResponse(
              url: url,
              statusCode: 200,
              headers: const {'content-type': 'text/html'},
              bodyText: '<html></html>',
            ),
          );

        final result = await RequestEngine(fetcher: fetcher).execute(
          url,
          options: const FetchOptions(
            timeout: Duration(seconds: 1),
            totalTimeout: Duration(seconds: 10),
          ),
          strategy: strategy,
        );

        expect(result.failure, isNull);
        expect(result.isSuccess, isTrue);
        expect(result.response?.statusCode, 200);
        expect(fetcher.requests.map((request) => request.method), <String>[
          'HEAD',
          'GET',
        ]);
      });

      test('${strategy.name}: operation deadline during HEAD does not start a '
          'fallback GET', () async {
        final pending = Completer<FetchResponse>();
        final fetcher = FakeFetcher(onMissing: (_) => pending.future);
        final elapsed = Stopwatch()..start();

        // The accelerated deadline timer fires while the context's own clock
        // still reports most of the ten-second budget. Only the error type
        // identifies the deadline, so this pins the guard independently of
        // the remaining-budget check that normally backs it up.
        final result = await _withAcceleratedTimers(
          () => RequestEngine(fetcher: fetcher).execute(
            Uri.parse('https://slow-head.test/'),
            options: const FetchOptions(
              timeout: Duration(seconds: 10),
              totalTimeout: Duration(seconds: 10),
            ),
            strategy: strategy,
          ),
        );

        expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
        expect(result.failure?.code, RequestFailureCode.timeout);
        expect(result.failure?.cause, isA<TimeoutException>());
        expect(fetcher.requests, hasLength(1));
        expect(fetcher.requests.single.method, 'HEAD');
      });

      test('${strategy.name}: caller cancellation during HEAD does not start a '
          'fallback GET', () async {
        final pending = Completer<FetchResponse>();
        final cancellation = Completer<void>();
        final fetcher = FakeFetcher(
          onMissing: (request) {
            if (request.method == 'HEAD') {
              unawaited(
                Future<void>.delayed(
                  const Duration(milliseconds: 10),
                  cancellation.complete,
                ),
              );
            }
            return pending.future;
          },
        );

        final result = await RequestEngine(fetcher: fetcher).execute(
          Uri.parse('https://slow-head.test/'),
          options: const FetchOptions(
            timeout: Duration(seconds: 10),
            totalTimeout: Duration(seconds: 10),
          ),
          context: RequestContext(cancellationSignal: cancellation.future),
          strategy: strategy,
        );

        expect(result.failure?.code, RequestFailureCode.cancelled);
        expect(fetcher.requests, hasLength(1));
        expect(fetcher.requests.single.method, 'HEAD');
      });

      test('${strategy.name}: HEAD reporting cancellation does not start a '
          'fallback GET', () async {
        final url = Uri.parse('https://cancelled-head.test/');
        final fetcher = FakeFetcher()
          ..registerHeadResponse(
            url,
            _transportError(url, FetchCancellationException(url)),
          )
          ..registerGetResponse(
            url,
            FakeFetcher.buildResponse(url: url, statusCode: 200),
          );

        final result = await RequestEngine(fetcher: fetcher).execute(
          url,
          options: const FetchOptions(totalTimeout: Duration(seconds: 10)),
          strategy: strategy,
        );

        expect(result.failure?.code, RequestFailureCode.cancelled);
        expect(fetcher.requests, hasLength(1));
        expect(fetcher.requests.single.method, 'HEAD');
      });
    }
  });

  test(
    'caller cancellation mid-request aborts the HttpFetcher transport',
    () async {
      final cancellation = Completer<void>();
      final abortObserved = Completer<void>();
      final client = RecordingHttpClient(
        handler: (request) async {
          cancellation.complete();
          await (request as http.AbortableRequest).abortTrigger;
          abortObserved.complete();
          throw http.RequestAbortedException(request.url);
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

      final result = await RequestEngine(fetcher: fetcher).execute(
        Uri.parse('https://slow.test/'),
        options: const FetchOptions(totalTimeout: Duration(seconds: 10)),
        context: RequestContext(cancellationSignal: cancellation.future),
      );

      expect(result.failure?.code, RequestFailureCode.cancelled);
      await expectLater(abortObserved.future, completes);
    },
  );

  test('cache identity includes all built-in policy controls', () {
    const compatible = RequestPolicy();
    const custom = RequestPolicy(
      forwardSensitiveHeadersThroughProxy: false,
      sensitiveHeaders: {'Authorization', 'X-Custom-Secret'},
    );

    expect(custom.cacheIdentity, isNot(compatible.cacheIdentity));
    expect(custom.cacheIdentity, contains('proxy=false'));
    expect(custom.cacheIdentity, contains('authorization,x-custom-secret'));
  });
}

/// Runs [body] with every timer of at least one second shortened to 20 ms.
///
/// [RequestContext] measures its budget with a real stopwatch, so a shortened
/// deadline timer fires while the context still reports remaining budget. This
/// deterministically widens the window between the engine's deadline timer
/// firing and the context clock observing the same deadline.
Future<T> _withAcceleratedTimers<T>(Future<T> Function() body) {
  return runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final shortened = duration >= const Duration(seconds: 1)
            ? const Duration(milliseconds: 20)
            : duration;
        return parent.createTimer(zone, shortened, callback);
      },
    ),
  );
}

/// A response for a request that failed before any HTTP status arrived.
FetchResponse _transportError(Uri url, Object error) {
  return FetchResponse(
    url: url,
    statusCode: null,
    headers: const <String, String>{},
    bodyBytes: const <int>[],
    truncated: false,
    duration: Duration.zero,
    error: error,
  );
}

FetchResponse _redirect(Uri from, Uri to) {
  return FakeFetcher.buildResponse(
    url: from,
    statusCode: 302,
    headers: {'location': to.toString()},
  );
}

/// A plain [Fetcher] on `http.Client` defaults, as a quick custom fetcher is
/// often written: it follows redirects itself and reports the final URL.
class _AutoFollowingFetcher implements Fetcher {
  final http.Client _client = http.Client();

  @override
  Future<FetchResponse> get(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
    int? maxBytes,
  }) => _send('GET', url, headers);

  @override
  Future<FetchResponse> head(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
  }) => _send('HEAD', url, headers);

  Future<FetchResponse> _send(
    String method,
    Uri url,
    Map<String, String>? headers,
  ) async {
    final request = http.Request(method, url)..headers.addAll(headers ?? {});
    final response = await _client.send(request);
    return FetchResponse(
      url: switch (response) {
        http.BaseResponseWithUrl(:final url) => url,
        _ => url,
      },
      statusCode: response.statusCode,
      headers: response.headers,
      bodyBytes: await response.stream.toBytes(),
      truncated: false,
      duration: Duration.zero,
    );
  }

  @override
  void close() => _client.close();
}

class _CapabilityFetcher extends FakeFetcher implements CapabilityAwareFetcher {
  _CapabilityFetcher({required this.capabilities});

  @override
  final FetcherCapabilities capabilities;
}

class _ResponseWithUrl extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _ResponseWithUrl(int statusCode, {required this.url})
    : super(const Stream<List<int>>.empty(), statusCode);

  @override
  final Uri url;
}
