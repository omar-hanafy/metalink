import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

class FixtureServer {
  FixtureServer._(this._server, this._fixtureRoot);

  final HttpServer _server;
  final String _fixtureRoot;

  static Future<FixtureServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixtureRoot = path.join(Directory.current.path, 'test', 'fixtures');
    final instance = FixtureServer._(server, fixtureRoot);
    server.listen(instance._handleRequest);
    return instance;
  }

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  Uri uri(String pathValue) {
    final normalized = pathValue.startsWith('/') ? pathValue : '/$pathValue';
    return baseUri.resolve(normalized);
  }

  Future<void> close() async {
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final method = request.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      return _respondStatus(request, 405, 'Method Not Allowed');
    }

    final pathValue = request.uri.path;

    final redirect = _redirects[pathValue];
    if (redirect != null) {
      final location = redirect.absolute
          ? request.requestedUri.resolve(redirect.location).toString()
          : redirect.location;
      return _respondRedirect(request, location);
    }

    if (pathValue == '/data/json') {
      return _respondBytes(
        request,
        utf8.encode('{"ok":true}'),
        contentType: 'application/json',
      );
    }

    if (pathValue == '/blocked') {
      return _respondHtmlStatus(
          request, 403, '<html><body>Access denied</body></html>');
    }

    if (pathValue == '/page/large') {
      return _respondLargePage(request);
    }

    if (pathValue.startsWith('/static/')) {
      return _respondAsset(request, pathValue);
    }

    final fixture = _routes[pathValue];
    if (fixture != null) {
      return _respondFixture(request, fixture);
    }

    return _respondStatus(request, 404, 'Not Found');
  }

  Future<void> _respondRedirect(
    HttpRequest request,
    String location,
  ) async {
    request.response.statusCode = 302;
    request.response.headers.set(HttpHeaders.locationHeader, location);
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    await request.response.close();
  }

  Future<void> _respondStatus(
    HttpRequest request,
    int statusCode,
    String message,
  ) async {
    request.response.statusCode = statusCode;
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method.toUpperCase() != 'HEAD') {
      request.response.headers.set(HttpHeaders.contentTypeHeader, 'text/plain');
      request.response.write(message);
    }
    await request.response.close();
  }

  Future<void> _respondHtmlStatus(
    HttpRequest request,
    int statusCode,
    String html,
  ) async {
    request.response.statusCode = statusCode;
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/html; charset=utf-8',
    );
    if (request.method.toUpperCase() != 'HEAD') {
      request.response.add(utf8.encode(html));
    }
    await request.response.close();
  }

  Future<void> _respondFixture(
    HttpRequest request,
    _FixtureRoute fixture,
  ) async {
    final filePath = path.join(_fixtureRoot, fixture.relativePath);
    final file = File(filePath);
    if (!await file.exists()) {
      return _respondStatus(request, 404, 'Missing fixture');
    }

    final bytes = await file.readAsBytes();
    return _respondBytes(
      request,
      bytes,
      contentType: fixture.contentType,
    );
  }

  Future<void> _respondAsset(HttpRequest request, String pathValue) async {
    final relative = pathValue.substring('/static/'.length);
    final assetRoot = path.join(_fixtureRoot, 'assets');
    final assetPath = path.normalize(path.join(assetRoot, relative));

    if (!path.isWithin(assetRoot, assetPath)) {
      return _respondStatus(request, 403, 'Forbidden');
    }

    final file = File(assetPath);
    if (!await file.exists()) {
      return _respondStatus(request, 404, 'Missing asset');
    }

    final bytes = await file.readAsBytes();
    final ext = path.extension(assetPath).toLowerCase();
    final contentType =
        _contentTypeByExtension[ext] ?? 'application/octet-stream';
    return _respondBytes(request, bytes, contentType: contentType);
  }

  Future<void> _respondLargePage(HttpRequest request) async {
    final buffer = StringBuffer();
    buffer.writeln('<!doctype html>');
    buffer.writeln('<html><head><title>Large Page</title></head><body>');
    for (var i = 0; i < 2000; i++) {
      buffer.writeln('Large content chunk $i');
    }
    buffer.writeln('</body></html>');
    return _respondBytes(
      request,
      utf8.encode(buffer.toString()),
      contentType: 'text/html; charset=utf-8',
    );
  }

  Future<void> _respondBytes(
    HttpRequest request,
    List<int> bytes, {
    required String contentType,
  }) async {
    request.response.statusCode = 200;
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    request.response.headers.set(HttpHeaders.contentLengthHeader, bytes.length);

    if (request.method.toUpperCase() != 'HEAD') {
      request.response.add(bytes);
    }
    await request.response.close();
  }
}

class _FixtureRoute {
  const _FixtureRoute(this.relativePath, this.contentType);

  final String relativePath;
  final String contentType;
}

class _RedirectRoute {
  const _RedirectRoute(this.location, {this.absolute = false});

  final String location;
  final bool absolute;
}

const Map<String, _FixtureRoute> _routes = {
  '/page/og-rich': _FixtureRoute(
    'html/og_rich.html',
    'text/html; charset=utf-8',
  ),
  '/page/twitter-only': _FixtureRoute(
    'html/twitter_only.html',
    'text/html; charset=utf-8',
  ),
  '/page/jsonld-heavy': _FixtureRoute(
    'html/jsonld_heavy.html',
    'text/html; charset=utf-8',
  ),
  '/page/mixed-sources': _FixtureRoute(
    'html/mixed_sources.html',
    'text/html; charset=utf-8',
  ),
  '/page/relative-urls': _FixtureRoute(
    'html/relative_urls.html',
    'text/html; charset=utf-8',
  ),
  '/page/base-href': _FixtureRoute(
    'html/base_href_integration.html',
    'text/html; charset=utf-8',
  ),
  '/page/malformed-meta': _FixtureRoute(
    'html/malformed_meta.html',
    'text/html; charset=utf-8',
  ),
  '/page/media-rich': _FixtureRoute(
    'html/media_rich.html',
    'text/html; charset=utf-8',
  ),
  '/page/i18n': _FixtureRoute(
    'html/i18n_page.html',
    'text/html; charset=utf-8',
  ),
  '/page/oembed-only': _FixtureRoute(
    'html/oembed_only.html',
    'text/html; charset=utf-8',
  ),
  '/page/manifest-only': _FixtureRoute(
    'html/manifest_only.html',
    'text/html; charset=utf-8',
  ),
  '/page/no-charset': _FixtureRoute(
    'html/no_charset.html',
    'text/html',
  ),
  '/page/standard-meta': _FixtureRoute(
    'html/standard_meta.html',
    'text/html; charset=utf-8',
  ),
  '/oembed.json': _FixtureRoute(
    'json/oembed.json',
    'application/json+oembed; charset=utf-8',
  ),
  '/manifest.json': _FixtureRoute(
    'json/manifest.json',
    'application/manifest+json; charset=utf-8',
  ),
  '/oembed.xml': _FixtureRoute(
    'xml/oembed.xml',
    'application/xml+oembed; charset=utf-8',
  ),
};

const Map<String, _RedirectRoute> _redirects = {
  '/r/short': _RedirectRoute('/page/og-rich'),
  '/r/chain1': _RedirectRoute('/r/chain2'),
  '/r/chain2': _RedirectRoute('/page/og-rich'),
  '/r/absolute': _RedirectRoute('/page/og-rich', absolute: true),
  '/r/loop': _RedirectRoute('/r/loop'),
};

const Map<String, String> _contentTypeByExtension = {
  '.html': 'text/html; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.ico': 'image/x-icon',
  '.mp4': 'video/mp4',
  '.mp3': 'audio/mpeg',
  '.txt': 'text/plain; charset=utf-8',
};
