import 'dart:convert';
import 'dart:io';

import 'package:metalink/metalink.dart';
import 'package:test/test.dart';

import '../../support/fake_fetcher.dart';

/// URL userinfo is a credential: dart:io sends it as `Authorization: Basic`.
void main() {
  final basicAuth = 'Basic ${base64.encode(utf8.encode('alice:s3cret'))}';

  group('URL userinfo credentials', () {
    late _LoggingServer origin;
    late _LoggingServer other;

    setUp(() async {
      origin = await _LoggingServer.start();
      other = await _LoggingServer.start();
    });

    tearDown(() async {
      await origin.close();
      await other.close();
    });

    test(
      'reach the document request but not oEmbed or manifest requests',
      () async {
        origin.routes['/page'] = (request) => _html(
          request,
          '<html><head><title>Private</title>'
          '<link rel="manifest" href="/manifest.json">'
          '<link rel="alternate" type="application/json+oembed" '
          'href="/oembed.json">'
          '</head></html>',
        );
        origin.routes['/manifest.json'] = (request) =>
            _json(request, <String, Object?>{'name': 'Private App'});
        origin.routes['/oembed.json'] = (request) => _json(
          request,
          <String, Object?>{'type': 'link', 'version': '1.0', 'title': 'E'},
        );
        final client = MetaLinkClient(
          options: const MetaLinkClientOptions(
            cache: CacheOptions(enabled: false),
            extract: ExtractOptions(enableOEmbed: true, enableManifest: true),
          ),
        );
        addTearDown(client.dispose);

        final result = await client.extract(
          'http://alice:s3cret@127.0.0.1:${origin.port}/page',
        );

        expect(result.metadata.manifest?.name, 'Private App');
        expect(result.metadata.oembed?.title, 'E');
        expect(origin.authorizationFor('/page'), everyElement(basicAuth));
        expect(origin.authorizationFor('/page'), isNotEmpty);
        expect(origin.authorizationFor('/manifest.json'), <String?>[null]);
        expect(origin.authorizationFor('/oembed.json'), <String?>[null]);
      },
    );

    for (final strip in <bool>[true, false]) {
      test(
        '${strip ? 'are stripped' : 'are kept'} on a cross-origin redirect '
        'when stripSensitiveHeadersOnCrossOriginRedirect is $strip',
        () async {
          origin.routes['/start'] = (request) => _redirect(request, '/same');
          origin.routes['/same'] = (request) => _redirect(
            request,
            'http://alice:s3cret@127.0.0.1:${other.port}/landing',
          );
          other.routes['/landing'] = (request) => _html(request, '<html/>');
          final fetcher = HttpFetcher();
          addTearDown(fetcher.close);

          final result = await RequestEngine(fetcher: fetcher).execute(
            Uri.parse('http://alice:s3cret@127.0.0.1:${origin.port}/start'),
            options: FetchOptions(
              requestPolicy: RequestPolicy(
                stripSensitiveHeadersOnCrossOriginRedirect: strip,
              ),
            ),
          );

          expect(result.failure, isNull);
          expect(result.redirects, hasLength(2));
          // Same-origin hops keep the caller's credentials.
          expect(origin.authorizationFor('/start'), <String?>[basicAuth]);
          expect(origin.authorizationFor('/same'), <String?>[basicAuth]);
          expect(other.authorizationFor('/landing'), <String?>[
            strip ? null : basicAuth,
          ]);
          expect(result.finalUrl.userInfo, strip ? isEmpty : 'alice:s3cret');
        },
      );
    }
  });

  group('URL userinfo and a rewrite proxy', () {
    final target = Uri.parse('https://alice:s3cret@example.com/page');
    const proxyUrl = 'https://proxy.test/fetch?url={urlEncoded}';

    Future<Uri> proxiedRequestUrl(RequestPolicy policy) async {
      final fetcher = FakeFetcher(
        onMissing: (request) =>
            FakeFetcher.buildResponse(url: request.url, statusCode: 200),
      );
      final result = await RequestEngine(fetcher: fetcher).execute(
        target,
        options: FetchOptions(proxyUrl: proxyUrl, requestPolicy: policy),
      );
      expect(result.failure, isNull);
      return fetcher.requests.single.url;
    }

    test(
      'are not embedded when the policy keeps secrets from the proxy',
      () async {
        for (final policy in <RequestPolicy>[
          const RequestPolicy(forwardSensitiveHeadersThroughProxy: false),
          RequestPolicy.secure(),
        ]) {
          final requested = await proxiedRequestUrl(policy);

          expect(requested.host, 'proxy.test');
          expect(requested.queryParameters['url'], 'https://example.com/page');
          expect(requested.toString(), isNot(contains('s3cret')));
          expect(requested.toString(), isNot(contains('alice')));
        }
      },
    );

    test('are still embedded when the policy forwards secrets', () async {
      final requested = await proxiedRequestUrl(const RequestPolicy());

      expect(
        requested.queryParameters['url'],
        'https://alice:s3cret@example.com/page',
      );
    });
  });
}

typedef _Route = Future<void> Function(HttpRequest request);

class _LoggingServer {
  _LoggingServer._(this._server) {
    _server.listen((request) async {
      log.add((request.uri.path, request.headers.value('authorization')));
      final route = routes[request.uri.path];
      if (route == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } else {
        await route(request);
      }
    });
  }

  static Future<_LoggingServer> start() async =>
      _LoggingServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final Map<String, _Route> routes = <String, _Route>{};
  final List<(String, String?)> log = <(String, String?)>[];

  int get port => _server.port;

  List<String?> authorizationFor(String path) => <String?>[
    for (final (loggedPath, authorization) in log)
      if (loggedPath == path) authorization,
  ];

  Future<void> close() => _server.close(force: true);
}

Future<void> _html(HttpRequest request, String body) {
  request.response
    ..headers.contentType = ContentType.html
    ..write(request.method == 'HEAD' ? '' : body);
  return request.response.close();
}

Future<void> _json(HttpRequest request, Map<String, Object?> body) {
  request.response
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  return request.response.close();
}

Future<void> _redirect(HttpRequest request, String location) {
  request.response
    ..statusCode = HttpStatus.found
    ..headers.set(HttpHeaders.locationHeader, location);
  return request.response.close();
}
