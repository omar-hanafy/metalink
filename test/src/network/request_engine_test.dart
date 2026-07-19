import 'dart:async';

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

      final result = await RequestEngine(
        fetcher: fetcher,
      ).execute(first, options: const FetchOptions(maxRedirects: 0));

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

        final result = await RequestEngine(
          fetcher: fetcher,
        ).execute(first, options: const FetchOptions(maxRedirects: 1));

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

      final result = await RequestEngine(
        fetcher: fetcher,
      ).execute(first, options: const FetchOptions(maxRedirects: 1));

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

      final result = await RequestEngine(
        fetcher: fetcher,
      ).execute(first, options: const FetchOptions(maxRedirects: 10));

      expect(result.failure?.code, RequestFailureCode.redirectLoop);
      expect(fetcher.requests, hasLength(3));
    });
  });

  group('policy boundary', () {
    test('rejects an async initial target before transport', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://blocked.test/');
      final policy = RequestPolicy(
        targetValidator: (target) async {
          await Future<void>.delayed(Duration.zero);
          return const RequestPolicyDecision.reject('blocked');
        },
      );

      final result = await RequestEngine(
        fetcher: fetcher,
      ).execute(url, options: FetchOptions(requestPolicy: policy));

      expect(result.failure?.code, RequestFailureCode.policyRejected);
      expect(fetcher.requests, isEmpty);
    });

    test('validator exceptions fail closed without escaping', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://policy.test/');
      final policy = RequestPolicy(
        targetValidator: (_) => throw StateError('validator failed'),
      );

      final result = await RequestEngine(
        fetcher: fetcher,
      ).execute(url, options: FetchOptions(requestPolicy: policy));

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

      final result = await RequestEngine(
        fetcher: fetcher,
      ).execute(first, options: FetchOptions(requestPolicy: policy));

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

      final result = await RequestEngine(
        fetcher: fetcher,
      ).execute(start, options: const FetchOptions());

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

  test(
    'complete deadline stops a legacy fetcher that does not honor timeout',
    () async {
      final pending = Completer<FetchResponse>();
      final fetcher = FakeFetcher(onMissing: (_) => pending.future);

      final result = await RequestEngine(fetcher: fetcher).execute(
        Uri.parse('https://slow.test/'),
        options: const FetchOptions(
          timeout: Duration(seconds: 1),
          totalTimeout: Duration(milliseconds: 10),
        ),
      );

      expect(result.failure?.code, RequestFailureCode.timeout);
      expect(fetcher.requests, hasLength(1));
    },
  );

  test('configured deadline bounds a cancellation-only context', () async {
    final pending = Completer<FetchResponse>();
    final cancellation = Completer<void>();
    final fetcher = FakeFetcher(onMissing: (_) => pending.future);

    final result = await RequestEngine(fetcher: fetcher).execute(
      Uri.parse('https://slow.test/'),
      options: const FetchOptions(
        timeout: Duration(seconds: 1),
        totalTimeout: Duration(milliseconds: 10),
      ),
      context: RequestContext(cancellationSignal: cancellation.future),
    );

    expect(result.failure?.code, RequestFailureCode.timeout);
    expect(fetcher.requests, hasLength(1));
  });

  test('expired HEAD budget does not start a fallback GET', () async {
    final pending = Completer<FetchResponse>();
    final fetcher = FakeFetcher(onMissing: (_) => pending.future);

    final result = await RequestEngine(fetcher: fetcher).execute(
      Uri.parse('https://slow.test/'),
      options: const FetchOptions(
        timeout: Duration(seconds: 1),
        totalTimeout: Duration(milliseconds: 10),
      ),
      strategy: RequestMethodStrategy.headThenGet,
    );

    expect(result.failure?.code, RequestFailureCode.timeout);
    expect(fetcher.requests, hasLength(1));
    expect(fetcher.requests.single.method, 'HEAD');
  });

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

FetchResponse _redirect(Uri from, Uri to) {
  return FakeFetcher.buildResponse(
    url: from,
    statusCode: 302,
    headers: {'location': to.toString()},
  );
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
